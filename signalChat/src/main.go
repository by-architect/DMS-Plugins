// Command signal-chat-bridge connects DMS to Signal.
//
// It is a DMS chat provider bridge: it translates Signal into newline-delimited
// JSON on stdout, and reads commands as JSON lines on stdin. See
// docs/CHAT-PLUGINS.md in the DankMaterialShell repository for the contract.
//
// It deliberately does very little. The DMS backend owns the message store,
// unread counts, pagination, the attachment cache, notifications and search;
// this program only speaks Signal and reports what happened.
//
// Signal itself is reached through signal-cli, which this bridge runs as a child
// process and drives over JSON-RPC. That is the whole reason this file is short:
// signal-cli holds the protocol, the keys and the crypto, and none of it is
// reimplemented here.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	// Announce before anything else. Capabilities are what the UI gates its
	// affordances on, so claiming something unimplemented means offering a
	// button that fails.
	//
	// Notably absent: search, because signal-cli has no server-side search and
	// the host's local search covers it; and threads and richText, which Signal
	// has no concept of.
	emitEvent("ready", map[string]any{
		"protocol": ProtocolVersion,
		"capabilities": []string{
			"send", "markRead", "media", "reply", "revoke", "groups",
		},
	})

	b := newBridge()

	// A terminating signal should stop signal-cli rather than orphan a JVM that
	// still holds the account.
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
			// exiting here would take down a working Signal session.
			logf("warn", "unparseable call: %v", err)
			continue
		}
		b.dispatch(c)
	}

	if err := scanner.Err(); err != nil {
		logf("error", "stdin failed: %v", err)
	}

	// Stdin closing means the host has gone; stop signal-cli with us.
	b.shutdown()
}

func (b *bridge) dispatch(c call) {
	ctx := context.Background()

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
		b.handleHistory(c)
	case "login":
		b.handleLogin(ctx, c)
	case "logout":
		b.handleLogout(ctx, c)
	case "revoke":
		b.handleRevoke(ctx, c)
	case "shutdown":
		ok(c.ID, nil)
		b.shutdown()
		os.Exit(0)

	default:
		// Answering rather than ignoring is what keeps this bridge working
		// against a newer host: it learns what is unsupported instead of
		// waiting for a reply that never arrives.
		fail(c.ID, "unknown_method", "signal bridge does not implement %s", c.Method)
	}
}
