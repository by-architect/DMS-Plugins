package main

import (
	"encoding/json"
	"fmt"
	"time"
)

// envelope is one incoming Signal message, as signal-cli reports it.
type envelope struct {
	Source       string `json:"source"`
	SourceNumber string `json:"sourceNumber"`
	SourceUUID   string `json:"sourceUuid"`
	SourceName   string `json:"sourceName"`
	Timestamp    int64  `json:"timestamp"`

	DataMessage    *dataMessage    `json:"dataMessage"`
	SyncMessage    *syncMessage    `json:"syncMessage"`
	ReceiptMessage *receiptMessage `json:"receiptMessage"`
	EditMessage    *editMessage    `json:"editMessage"`
}

type dataMessage struct {
	Timestamp    int64        `json:"timestamp"`
	Message      string       `json:"message"`
	Attachments  []attachment `json:"attachments"`
	GroupInfo    *groupInfo   `json:"groupInfo"`
	Quote        *quote       `json:"quote"`
	RemoteDelete *struct {
		Timestamp int64 `json:"timestamp"`
	} `json:"remoteDelete"`
	Sticker *struct {
		PackID    string `json:"packId"`
		StickerID int    `json:"stickerId"`
	} `json:"sticker"`
	// Reactions are deliberately not surfaced as messages: the contract has no
	// reaction concept, and turning each one into a message would fill a
	// conversation with noise nobody sent.
	Reaction *struct {
		Emoji               string `json:"emoji"`
		TargetAuthor        string `json:"targetAuthor"`
		TargetSentTimestamp int64  `json:"targetSentTimestamp"`
		IsRemove            bool   `json:"isRemove"`
	} `json:"reaction"`
}

type editMessage struct {
	TargetSentTimestamp int64        `json:"targetSentTimestamp"`
	DataMessage         *dataMessage `json:"dataMessage"`
}

type groupInfo struct {
	GroupID   string `json:"groupId"`
	GroupName string `json:"groupName"`
	Type      string `json:"type"`
}

type quote struct {
	ID           int64        `json:"id"`
	Author       string       `json:"author"`
	AuthorNumber string       `json:"authorNumber"`
	AuthorUUID   string       `json:"authorUuid"`
	Text         string       `json:"text"`
	Attachments  []attachment `json:"attachments"`
}

type attachment struct {
	ContentType string `json:"contentType"`
	Filename    string `json:"filename"`
	ID          string `json:"id"`
	Size        int64  `json:"size"`
	Width       int    `json:"width"`
	Height      int    `json:"height"`
	IsVoiceNote bool   `json:"isVoiceNote"`
	IsSticker   bool   `json:"isSticker"`
}

type syncMessage struct {
	SentMessage  *sentMessage `json:"sentMessage"`
	ReadMessages []struct {
		Sender    string `json:"sender"`
		Timestamp int64  `json:"timestamp"`
	} `json:"readMessages"`
}

// sentMessage is this account's own message, echoed from another device.
type sentMessage struct {
	Destination       string `json:"destination"`
	DestinationNumber string `json:"destinationNumber"`
	DestinationUUID   string `json:"destinationUuid"`
	dataMessage
}

type receiptMessage struct {
	When       int64   `json:"when"`
	IsDelivery bool    `json:"isDelivery"`
	IsRead     bool    `json:"isRead"`
	IsViewed   bool    `json:"isViewed"`
	Timestamps []int64 `json:"timestamps"`
}

// onNotification is the whole inbound path: signal-cli notifications in,
// contract events out. Everything Signal-shaped stops here.
func (b *bridge) onNotification(method string, params json.RawMessage) {
	if method != "receive" {
		// signal-cli also emits lifecycle notifications this bridge has no use
		// for. Ignored rather than logged as errors.
		return
	}

	var wrapper struct {
		Envelope envelope `json:"envelope"`
		Account  string   `json:"account"`
	}
	if err := json.Unmarshal(params, &wrapper); err != nil {
		logf("debug", "unparseable receive notification: %v", err)
		return
	}

	// With one account this is always ours, but signal-cli can serve several and
	// a stray envelope would otherwise land in the wrong provider's store.
	if account := b.getAccount(); account != "" && wrapper.Account != "" && wrapper.Account != account {
		return
	}

	b.handleEnvelope(wrapper.Envelope)
}

func (b *bridge) handleEnvelope(env envelope) {
	switch {
	case env.ReceiptMessage != nil:
		b.onReceipt(env.ReceiptMessage)

	case env.SyncMessage != nil:
		b.onSync(env)

	case env.EditMessage != nil && env.EditMessage.DataMessage != nil:
		// An edit replaces the original. Because chat and message events are
		// upserts keyed on id, re-emitting under the *target* timestamp updates
		// the message in place instead of appending a near-duplicate.
		edited := *env.EditMessage.DataMessage
		edited.Timestamp = env.EditMessage.TargetSentTimestamp
		b.onDataMessage(env, &edited, false)

	case env.DataMessage != nil:
		b.onDataMessage(env, env.DataMessage, false)
	}
}

// onDataMessage converts one message, incoming or echoed from our own device.
func (b *bridge) onDataMessage(env envelope, dm *dataMessage, fromMe bool) {
	if dm.Reaction != nil {
		return
	}

	if dm.RemoteDelete != nil {
		chatID := b.chatIDFor(env, dm, fromMe)
		emitEvent("deleted", map[string]any{
			"chatId":    chatID,
			"messageId": messageID(b.authorOf(env, fromMe), dm.RemoteDelete.Timestamp),
		})
		return
	}

	msg := b.convert(env, dm, fromMe)
	if msg == nil {
		return
	}

	emitEvent("message", map[string]any{"message": msg})

	if msg.MediaRef != "" && msg.MediaPath == "" {
		go b.autoDownload(*msg)
	}

	// Keep the conversation's activity line in step. The host would derive it,
	// but sending it means the chat list reorders immediately rather than after
	// the next full sync.
	chat := chatObj{
		ID:       msg.ChatID,
		LastTS:   msg.TS,
		LastText: previewOf(msg),
	}
	if dm.GroupInfo != nil && dm.GroupInfo.GroupName != "" {
		chat.Name = dm.GroupInfo.GroupName
		chat.IsGroup = true
	} else if dm.GroupInfo != nil {
		chat.IsGroup = true
	}
	emitEvent("chat", map[string]any{"chat": chat})
}

// onSync handles what our own other devices tell us.
func (b *bridge) onSync(env envelope) {
	sync := env.SyncMessage

	if sync.SentMessage != nil {
		inner := sync.SentMessage.dataMessage
		b.onDataMessage(env, &inner, true)
	}

	// Read somewhere else: clear it here too, so unread counts agree across
	// devices instead of this one insisting on messages the user has read.
	for _, r := range sync.ReadMessages {
		emitEvent("status", map[string]any{
			"messageId": messageID(r.Sender, r.Timestamp),
			"status":    "read",
		})
	}
}

// onReceipt maps Signal's receipts onto the contract's status ladder. The host
// ratchets these, so an out-of-order receipt cannot move a message backwards.
func (b *bridge) onReceipt(r *receiptMessage) {
	var status string
	switch {
	case r.IsRead, r.IsViewed:
		status = "read"
	case r.IsDelivery:
		status = "delivered"
	default:
		return
	}

	// A receipt is about messages *we* sent, so the author is this account.
	self := b.getAccount()
	for _, ts := range r.Timestamps {
		emitEvent("status", map[string]any{
			"messageId": messageID(self, ts),
			"status":    status,
		})
	}
}

// syncChats publishes what signal-cli already knows: the groups this account is
// in, and every contact with the identifiers they can be found by.
//
// Without this a conversation only becomes searchable once a message arrives in
// it, so a freshly linked account would appear empty and searching a phone
// number would find nothing at all.
func (b *bridge) syncChats() {
	client := b.getRPC()
	account := b.getAccount()
	if client == nil || account == "" {
		return
	}

	var chats []chatObj

	var groups []group
	if err := client.callInto("listGroups", map[string]any{"account": account, "detailed": true}, &groups); err != nil {
		logf("debug", "could not list groups: %v", err)
	} else {
		for _, g := range groups {
			if g.ID == "" {
				continue
			}
			chats = append(chats, chatObj{
				ID:      groupChatID(g.ID),
				Name:    groupDisplayName(g),
				IsGroup: true,
				Tags:    groupTagsFor(g),
			})
		}
	}

	var contacts []contact
	if err := client.callInto("listContacts", map[string]any{"account": account}, &contacts); err != nil {
		logf("debug", "could not list contacts: %v", err)
	} else {
		for _, c := range contacts {
			id := contactID(c)
			if id == "" || c.IsHidden {
				continue
			}
			name := contactDisplayName(c)
			handles := handlesFor(c)
			// Nothing to contribute: no name to search for, no handle to match.
			if name == "" && len(handles) == 0 {
				continue
			}
			chats = append(chats, chatObj{
				ID:      directChatID(id),
				Name:    name,
				Handles: handles,
				Tags:    tagsFor(c, account),
			})
		}
	}

	// Batched: an address book runs to thousands, and the host writes a batch in
	// one transaction.
	const batchSize = 500
	for start := 0; start < len(chats); start += batchSize {
		end := start + batchSize
		if end > len(chats) {
			end = len(chats)
		}
		emitEvent("chats", map[string]any{"chats": chats[start:end]})
	}

	if len(chats) > 0 {
		logf("info", "published %d known conversations", len(chats))
	}
}

// previewOf is the chat-list line for a message.
func previewOf(msg *messageObj) string {
	if msg.Text != "" {
		return msg.Text
	}
	if p := placeholderFor(msg.Kind); p != "" {
		return p
	}
	if msg.FileName != "" {
		return msg.FileName
	}
	return ""
}

func placeholderFor(kind string) string {
	switch kind {
	case "image":
		return "📷 Photo"
	case "video":
		return "🎥 Video"
	case "audio":
		return "🎤 Voice message"
	case "document":
		return "📄 Document"
	case "sticker":
		return "🌟 Sticker"
	case "deleted":
		return "🚫 Deleted message"
	}
	return ""
}

// messageID is the contract id for a Signal message.
//
// Signal identifies a message by who sent it and when, not by an id of its own,
// so the pair is the id. Composed rather than hashed so the bridge can take it
// back apart -- reading a receipt or deleting a message needs the timestamp.
func messageID(author string, ts int64) string {
	return fmt.Sprintf("%s:%d", author, ts)
}

func tsOrNow(ts int64) int64 {
	if ts <= 0 {
		return time.Now().UnixMilli()
	}
	return ts
}
