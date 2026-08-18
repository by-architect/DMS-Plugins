package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

// ProtocolVersion is the DMS chat bridge contract this speaks. The host refuses
// a version it does not recognise rather than parsing it on a guess.
const ProtocolVersion = 1

// This file is deliberately free of WhatsApp: it is the framing layer, and
// exists unchanged in every bridge. Everything protocol-specific lives in
// bridge.go / events.go / messages.go.

type call struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type reply struct {
	ID     int      `json:"id"`
	OK     bool     `json:"ok"`
	Result any      `json:"result,omitempty"`
	Error  *errInfo `json:"error,omitempty"`
}

type errInfo struct {
	Code    string `json:"code"`
	Message string `json:"message,omitempty"`
}

// chatObj and messageObj mirror the shapes in docs/CHAT-PLUGINS.md. Fields the
// bridge has nothing to say about are omitted so the host keeps whatever it
// already knows -- a partial update must never blank an earlier one.
type chatObj struct {
	ID         string `json:"id"`
	Name       string `json:"name,omitempty"`
	IsGroup    bool   `json:"isGroup,omitempty"`
	LastTS     int64  `json:"lastTs,omitempty"`
	LastText   string `json:"lastText,omitempty"`
	Unread     *int   `json:"unread,omitempty"`
	Archived   bool   `json:"archived,omitempty"`
	Muted      bool   `json:"muted,omitempty"`
	AvatarPath string `json:"avatarPath,omitempty"`
	// Handles are the reachable identifiers for this conversation -- for
	// WhatsApp, the phone number. Sent explicitly because the id no longer
	// contains one: WhatsApp addresses contacts by LID, a privacy identifier.
	Handles []string `json:"handles,omitempty"`
	// Tags say what kind of conversation this is, so it can be filtered without
	// the shell knowing anything about WhatsApp.
	Tags []string `json:"tags,omitempty"`
}

type messageObj struct {
	ID         string `json:"id"`
	ChatID     string `json:"chatId"`
	TS         int64  `json:"ts"`
	FromMe     bool   `json:"fromMe,omitempty"`
	SenderID   string `json:"senderId,omitempty"`
	SenderName string `json:"senderName,omitempty"`
	Kind       string `json:"kind,omitempty"`
	Text       string `json:"text,omitempty"`
	Status     string `json:"status,omitempty"`
	ReplyTo    string `json:"replyTo,omitempty"`

	// A link the message is about. WhatsApp sends this with the message, so it
	// costs nothing and never involves fetching the page ourselves.
	LinkURL   string `json:"linkUrl,omitempty"`
	LinkTitle string `json:"linkTitle,omitempty"`
	LinkDesc  string `json:"linkDesc,omitempty"`

	// MediaPath is set once an attachment has actually been written to the
	// media directory the host provided; until then only a thumbnail and a ref
	// are sent.
	MediaPath  string `json:"mediaPath,omitempty"`
	MediaBytes string `json:"mediaBytes,omitempty"`
	MediaRef   string `json:"mediaRef,omitempty"`
	MediaMime  string `json:"mediaMime,omitempty"`
	MediaW     int    `json:"mediaW,omitempty"`
	MediaH     int    `json:"mediaH,omitempty"`
	FileName   string `json:"fileName,omitempty"`
	FileSize   int64  `json:"fileSize,omitempty"`
	Duration   int    `json:"duration,omitempty"`
}

// out serialises stdout across the reader goroutine and every WhatsApp event
// handler, which fire concurrently.
var out = struct {
	mu sync.Mutex
	w  *bufio.Writer
}{w: bufio.NewWriter(os.Stdout)}

// emit writes one protocol frame.
//
// Compact and on a single line, always: a pretty-printed object embeds
// newlines, which splits it across lines and desyncs the host's reader for the
// remainder of the session.
func emit(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		logf("error", "could not encode frame: %v", err)
		return
	}

	out.mu.Lock()
	defer out.mu.Unlock()
	out.w.Write(data)
	out.w.WriteByte('\n')
	out.w.Flush()
}

func emitEvent(event string, fields map[string]any) {
	frame := map[string]any{"event": event}
	for k, v := range fields {
		frame[k] = v
	}
	emit(frame)
}

func emitState(state string) {
	emitEvent("state", map[string]any{"state": state})
}

func ok(id int, result any) {
	if result == nil {
		emit(reply{ID: id, OK: true})
		return
	}
	emit(reply{ID: id, OK: true, Result: result})
}

func fail(id int, code, format string, args ...any) {
	emit(reply{ID: id, OK: false, Error: &errInfo{
		Code:    code,
		Message: fmt.Sprintf(format, args...),
	}})
}

// logf writes a diagnostic to stderr, which the host tails into its log and
// surfaces in `dms chat tail`.
//
// Never bare text on stdout -- that stream is protocol. This is the single
// easiest way to break a bridge.
func logf(level, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintln(os.Stderr, msg)
	emitEvent("log", map[string]any{"level": level, "text": msg})
}
