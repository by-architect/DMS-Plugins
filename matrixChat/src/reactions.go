package main

import (
	"context"
	"encoding/json"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Reactions, both ways.
//
// A Matrix reaction is an event of its own, m.reaction, annotating the message
// it is on with a key -- an emoji, usually. Taking one back is redacting that
// event, which arrives as a deletion naming the reaction's id; the host knows a
// deletion can name a reaction, and drops it.
//
// In an encrypted room a reaction is encrypted like anything else. The crypto
// helper hands it on decrypted, so it reaches onReaction the same way.

// reactionFor reads an m.reaction event, or returns nil for one that annotates
// nothing.
func (b *bridge) reactionFor(evt *event.Event) *reactionObj {
	content, ok := evt.Content.Parsed.(*event.ReactionEventContent)
	if !ok {
		return nil
	}
	rel := content.RelatesTo
	if rel.Type != event.RelAnnotation || rel.EventID == "" || rel.Key == "" {
		return nil
	}
	return &reactionObj{
		ID:         string(evt.ID),
		ChatID:     string(evt.RoomID),
		MessageID:  string(rel.EventID),
		Key:        rel.Key,
		SenderID:   string(evt.Sender),
		SenderName: b.senderName(evt.RoomID, evt.Sender),
		FromMe:     evt.Sender == b.selfID(),
		TS:         evt.Timestamp,
	}
}

// onReaction reports a reaction arriving in the sync.
//
// An initial sync's are held with the messages they belong to and sent after
// them, the way its messages are: they are history, not news.
func (b *bridge) onReaction(ctx context.Context, evt *event.Event) {
	r := b.reactionFor(evt)
	if r == nil {
		return
	}
	if isInitialSync(ctx) {
		b.mu.Lock()
		b.heldReactions = append(b.heldReactions, *r)
		b.mu.Unlock()
		return
	}
	emitEvent("reaction", map[string]any{"reaction": r})
}

// emitReactions sends reactions as the batch event.
func emitReactions(reactions []reactionObj) {
	const batchSize = 200
	for start := 0; start < len(reactions); start += batchSize {
		end := min(start+batchSize, len(reactions))
		emitEvent("reactions", map[string]any{"reactions": reactions[start:end]})
	}
}

// handleReact puts a reaction on a message, answering with its id -- which is
// what the host takes it back by.
func (b *bridge) handleReact(ctx context.Context, c call) {
	var params struct {
		ChatID    string `json:"chatId"`
		MessageID string `json:"messageId"`
		Key       string `json:"key"`
	}
	_ = json.Unmarshal(c.Params, &params)
	if params.ChatID == "" || params.MessageID == "" || params.Key == "" {
		fail(c.ID, "bad_params", "chatId, messageId and key are required")
		return
	}

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return
	}
	roomID := id.RoomID(params.ChatID)

	// The same refusal as a message: a reaction sent in plain text into an
	// encrypted room says who reacted to what, to the homeserver and anyone
	// who reads its database.
	encrypted, err := b.encryptionFor(ctx, client, roomID)
	if err != nil {
		fail(c.ID, "no_encryption", "This room is end-to-end encrypted and encryption is not working on this device, so the reaction was not sent.")
		return
	}

	sent, err := sendReaction(ctx, client, roomID, id.EventID(params.MessageID), params.Key, encrypted)
	if err != nil {
		fail(c.ID, "react_failed", "%s", serverMessage(err, "could not react"))
		return
	}
	ok(c.ID, map[string]any{"reactionId": string(sent)})
}

// sendReaction sends an m.reaction, encrypted in an encrypted room.
//
// mautrix leaves reactions out when it encrypts what a client sends, so in an
// encrypted room client.SendReaction put the emoji -- and so what somebody
// thought of a message -- in front of the homeserver in plain text. It is
// encrypted here the way Element does it; the relation stays readable outside
// the encryption, which is what lets the homeserver count reactions at all.
func sendReaction(ctx context.Context, client *mautrix.Client, roomID id.RoomID, target id.EventID, key string, encrypted bool) (id.EventID, error) {
	content := &event.ReactionEventContent{RelatesTo: event.RelatesTo{
		EventID: target,
		Type:    event.RelAnnotation,
		Key:     key,
	}}

	if !encrypted || client.Crypto == nil {
		resp, err := client.SendMessageEvent(ctx, roomID, event.EventReaction, content)
		if err != nil {
			return "", err
		}
		return resp.EventID, nil
	}

	sealed, err := client.Crypto.Encrypt(ctx, roomID, event.EventReaction, content)
	if err != nil {
		return "", err
	}
	resp, err := client.SendMessageEvent(ctx, roomID, event.EventEncrypted, sealed)
	if err != nil {
		return "", err
	}
	return resp.EventID, nil
}

// handleUnreact takes one of our reactions back, by redacting it.
func (b *bridge) handleUnreact(ctx context.Context, c call) {
	var params struct {
		ChatID     string `json:"chatId"`
		ReactionID string `json:"reactionId"`
	}
	_ = json.Unmarshal(c.Params, &params)
	if params.ChatID == "" || params.ReactionID == "" {
		fail(c.ID, "bad_params", "chatId and reactionId are required")
		return
	}

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return
	}
	if _, err := client.RedactEvent(ctx, id.RoomID(params.ChatID), id.EventID(params.ReactionID)); err != nil {
		fail(c.ID, "unreact_failed", "%s", serverMessage(err, "could not take the reaction back"))
		return
	}
	ok(c.ID, nil)
}
