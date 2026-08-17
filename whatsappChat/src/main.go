// Command whatsapp-chat-bridge connects DMS to WhatsApp.
//
// It is a DMS chat provider bridge: it translates WhatsApp into newline-
// delimited JSON on stdout, and reads commands as JSON lines on stdin. See
// docs/CHAT-PLUGINS.md in the DankMaterialShell repository for the contract.
//
// It deliberately does very little. The DMS backend owns the message store,
// unread counts, pagination, the attachment cache, notifications and search;
// this program only speaks WhatsApp and reports what happened. All whatsmeow
// types stay inside this binary, so a library change never reaches the shell.
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
	emitEvent("ready", map[string]any{
		"protocol": ProtocolVersion,
		"capabilities": []string{
			"send", "markRead", "media", "reply", "revoke", "groups", "presence",
		},
	})

	b := newBridge()

	// A terminating signal should log out of the socket cleanly rather than
	// leaving WhatsApp believing the device is still online.
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigChan
		b.shutdown()
		os.Exit(0)
	}()

	scanner := bufio.NewScanner(os.Stdin)
	// History-sync driven calls can be large; the default 64 KiB is not enough.
	scanner.Buffer(make([]byte, 0, 64*1024), 16<<20)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}

		var c call
		if err := json.Unmarshal(line, &c); err != nil {
			// A malformed call is the host's problem. Log it and keep serving:
			// exiting here would take down a working WhatsApp session.
			logf("warn", "unparseable call: %v", err)
			continue
		}
		b.dispatch(c)
	}

	if err := scanner.Err(); err != nil {
		logf("error", "stdin failed: %v", err)
	}

	// Stdin closing means the host has gone; disconnect cleanly.
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
		fail(c.ID, "unknown_method", "whatsapp bridge does not implement %s", c.Method)
	}
}
