// Command matrix-chat-bridge connects DMS to a Matrix homeserver.
//
// It is a DMS chat provider bridge: it translates Matrix into newline-delimited
// JSON on stdout, and reads commands as JSON lines on stdin. See
// docs/CHAT-PLUGINS.md in the DankMaterialShell repository for the contract.
//
// It deliberately does very little. The DMS backend owns the message store,
// unread counts, pagination, the attachment cache, notifications and search;
// this program only speaks Matrix and reports what happened.
//
// Run with -login for the interactive sign-in helper, which is how a session is
// created in the first place. See login.go.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	loginMode := flag.Bool("login", false, "sign in interactively and store a session, then exit")
	flag.Parse()

	if *loginMode {
		runLogin()
		return
	}

	// Announce before anything else. Capabilities are what the UI gates its
	// affordances on, so claiming something unimplemented means offering a
	// button that fails.
	//
	// Notably absent: search, because the host's local search covers what has
	// been received and Matrix's server-side search is a separate API this
	// bridge does not implement yet.
	//
	// "markdown" says how a message's text is written: Markdown, both ways.
	// Formatted messages arrive converted from their HTML, and what is sent
	// goes out formatted on Matrix. See markdown.go.
	//
	// "history" is older messages fetched from the homeserver as the
	// conversation is scrolled back (history.go); "reactions", "edit" and
	// "typing" are m.reaction, m.replace and m.typing both ways; "startChat"
	// opens a direct chat with @someone or joins #a:room (startchat.go); and
	// "mute" keeps a mute set here in step with the account's push rules
	// (pushrules.go).
	emitEvent("ready", map[string]any{
		"protocol": ProtocolVersion,
		"capabilities": []string{
			"send", "markRead", "media", "reply", "revoke", "groups", "richText",
			"markdown", "invites", "history", "reactions", "edit", "typing",
			"startChat", "mute",
		},
	})

	b := newBridge()

	// A terminating signal should close the crypto store cleanly. Leaving it
	// half-written is how a device loses the keys to its own history.
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigChan
		b.shutdown()
		os.Exit(0)
	}()

	scanner := bufio.NewScanner(os.Stdin)
	// A send with several attachments carries their paths; the default 64 KiB
	// is not always enough.
	scanner.Buffer(make([]byte, 0, 64*1024), 16<<20)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}

		var c call
		if err := json.Unmarshal(line, &c); err != nil {
			// A malformed call is the host's problem. Log it and keep serving:
			// exiting here would take down a working session.
			logf("warn", "unparseable call: %v", err)
			continue
		}
		b.dispatch(c)
	}

	if err := scanner.Err(); err != nil {
		logf("error", "stdin failed: %v", err)
	}

	// Stdin closing means the host has gone; stop syncing with it.
	b.shutdown()
}

// dispatch hands a call to its lane. Shutting down is the exception: it is
// answered here and now, since it ends the process.
func (b *bridge) dispatch(c call) {
	if c.Method == "shutdown" {
		ok(c.ID, nil)
		b.shutdown()
		os.Exit(0)
	}
	b.calls.run(laneFor(c), func() { b.handle(context.Background(), c) })
}

// handle answers one call.
func (b *bridge) handle(ctx context.Context, c call) {
	switch c.Method {
	case "configure":
		b.handleConfigure(ctx, c)
	case "send":
		b.handleSend(ctx, c)
	case "markRead":
		b.handleMarkRead(ctx, c)
	case "fetchMedia":
		b.handleFetchMedia(ctx, c)
	case "history":
		b.handleHistory(ctx, c)
	case "login":
		b.handleLogin(ctx, c)
	case "authSubmit":
		b.handleAuthSubmit(ctx, c)
	case "verify":
		b.handleVerify(ctx, c)
	case "logout":
		b.handleLogout(ctx, c)
	case "revoke":
		b.handleRevoke(ctx, c)
	case "acceptInvite":
		b.handleAcceptInvite(ctx, c)
	case "declineInvite":
		b.handleDeclineInvite(ctx, c)
	case "react":
		b.handleReact(ctx, c)
	case "unreact":
		b.handleUnreact(ctx, c)
	case "edit":
		b.handleEdit(ctx, c)
	case "typing":
		b.handleTyping(ctx, c)
	case "startChat":
		b.handleStartChat(ctx, c)
	case "setMuted":
		b.handleSetMuted(ctx, c)

	default:
		// Answering rather than ignoring is what keeps this bridge working
		// against a newer host: it learns what is unsupported instead of
		// waiting for a reply that never arrives.
		fail(c.ID, "unknown_method", "matrix bridge does not implement %s", c.Method)
	}
}
