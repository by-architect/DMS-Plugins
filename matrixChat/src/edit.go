package main

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Editing a message we sent, and saying that we are typing.

// handleEdit replaces the text of one of our messages, the way Element does: a
// new m.room.message whose m.new_content is the message as it now reads, with
// an m.replace relation to the original and a "* " fallback for clients that
// know nothing of edits. The text is Markdown like any message (setText).
//
// The host only offers this for our own text messages, which is also all a
// Matrix client will accept: an edit from anyone but the sender is ignored.
func (b *bridge) handleEdit(ctx context.Context, c call) {
	var params struct {
		ChatID    string `json:"chatId"`
		MessageID string `json:"messageId"`
		Text      string `json:"text"`
	}
	_ = json.Unmarshal(c.Params, &params)
	if params.ChatID == "" || params.MessageID == "" || strings.TrimSpace(params.Text) == "" {
		fail(c.ID, "bad_params", "chatId, messageId and text are required")
		return
	}

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return
	}
	roomID := id.RoomID(params.ChatID)

	if _, err := b.encryptionFor(ctx, client, roomID); err != nil {
		fail(c.ID, "no_encryption", "This room is end-to-end encrypted and encryption is not working on this device, so the edit was not sent.")
		return
	}

	if _, err := b.sendEdit(ctx, client, roomID, id.EventID(params.MessageID), params.Text); err != nil {
		fail(c.ID, "edit_failed", "%s", serverMessage(err, "could not edit the message"))
		return
	}
	ok(c.ID, nil)
}

// sendEdit builds and sends the replacement event.
func (b *bridge) sendEdit(ctx context.Context, client matrixSender, roomID id.RoomID, original id.EventID, text string) (id.EventID, error) {
	content := &event.MessageEventContent{MsgType: event.MsgText}
	setText(content, text)
	content.SetEdit(original)

	resp, err := client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		return "", err
	}
	return resp.EventID, nil
}

// typingTimeout is how long the homeserver shows us typing without hearing
// again. The shell repeats itself every few seconds while the user types, and
// says when they stop; this only matters when it never gets to.
const typingTimeout = 20 * time.Second

// onTyping reports who is typing in a room: the whole list each time, which is
// how Matrix sends it, without ourselves -- our own typing shows up there too.
func (b *bridge) onTyping(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.TypingEventContent)
	if !ok || evt.RoomID == "" || isInitialSync(ctx) {
		return
	}

	self := b.selfID()
	names := []string{}
	for _, user := range content.UserIDs {
		if user != self {
			names = append(names, b.senderName(evt.RoomID, user))
		}
	}
	emitEvent("typing", map[string]any{"chatId": string(evt.RoomID), "users": names})
}

// handleTyping tells the room we are typing, or have stopped -- unless the
// user has said not to, which is theirs to decide like read receipts are.
func (b *bridge) handleTyping(ctx context.Context, c call) {
	var params struct {
		ChatID string `json:"chatId"`
		Typing bool   `json:"typing"`
	}
	_ = json.Unmarshal(c.Params, &params)

	client := b.getClient()
	if client == nil || params.ChatID == "" || !b.settingBool("sendTypingNotifications", true) {
		ok(c.ID, nil)
		return
	}
	if _, err := client.UserTyping(ctx, id.RoomID(params.ChatID), params.Typing, typingTimeout); err != nil {
		// Nobody misses a typing notice; the next one is seconds away.
		logf("debug", "could not send a typing notice: %v", err)
	}
	ok(c.ID, nil)
}
