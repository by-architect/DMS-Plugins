package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------- conversion

// authorOf names who sent a message.
func (b *bridge) authorOf(env envelope, fromMe bool) string {
	if fromMe {
		return b.getAccount()
	}
	for _, candidate := range []string{env.SourceUUID, env.SourceNumber, env.Source} {
		if candidate != "" {
			return candidate
		}
	}
	return ""
}

// chatIDFor decides which conversation a message belongs to.
//
// For a group that is the group. For a direct message it is whoever is *not*
// us: the sender when it arrives, the destination when we sent it. Getting this
// backwards files your own replies under your own name.
func (b *bridge) chatIDFor(env envelope, dm *dataMessage, fromMe bool) string {
	if dm.GroupInfo != nil && dm.GroupInfo.GroupID != "" {
		return groupChatID(dm.GroupInfo.GroupID)
	}
	if fromMe {
		return directChatID(b.destinationOf(env))
	}
	return directChatID(b.authorOf(env, false))
}

// destinationOf reads the far end of a message we sent from another device.
func (b *bridge) destinationOf(env envelope) string {
	if env.SyncMessage == nil || env.SyncMessage.SentMessage == nil {
		return b.getAccount()
	}
	s := env.SyncMessage.SentMessage
	for _, candidate := range []string{s.DestinationUUID, s.DestinationNumber, s.Destination} {
		if candidate != "" {
			return candidate
		}
	}
	// No destination and no group: Signal's note-to-self.
	return b.getAccount()
}

// convert turns one Signal message into the contract's shape.
func (b *bridge) convert(env envelope, dm *dataMessage, fromMe bool) *messageObj {
	ts := tsOrNow(dm.Timestamp)
	if dm.Timestamp == 0 {
		ts = tsOrNow(env.Timestamp)
	}

	author := b.authorOf(env, fromMe)

	msg := &messageObj{
		ID:         messageID(author, ts),
		ChatID:     b.chatIDFor(env, dm, fromMe),
		TS:         ts,
		FromMe:     fromMe,
		SenderID:   author,
		SenderName: strings.TrimSpace(env.SourceName),
		Kind:       "text",
		Text:       dm.Message,
	}

	if fromMe {
		// Our own message came back from another device, so it is at least sent.
		// The host ratchets, so this can only move it forward.
		msg.Status = "sent"
	}

	if dm.Quote != nil {
		quoteAuthor := dm.Quote.AuthorUUID
		if quoteAuthor == "" {
			quoteAuthor = dm.Quote.AuthorNumber
		}
		if quoteAuthor == "" {
			quoteAuthor = dm.Quote.Author
		}
		msg.ReplyTo = messageID(quoteAuthor, dm.Quote.ID)
	}

	if dm.Sticker != nil {
		msg.Kind = "sticker"
	}

	// Only the first attachment rides on the message, because a message carries
	// one. Signal permits several; the rest are reported as their own messages
	// so each gets its own row rather than silently vanishing.
	if len(dm.Attachments) > 0 {
		b.applyAttachment(msg, dm.Attachments[0])

		for i, extra := range dm.Attachments[1:] {
			sibling := *msg
			sibling.ID = fmt.Sprintf("%s#%d", msg.ID, i+1)
			sibling.Text = ""
			sibling.ReplyTo = ""
			b.applyAttachment(&sibling, extra)
			emitEvent("message", map[string]any{"message": &sibling})
			if sibling.MediaRef != "" && sibling.MediaPath == "" {
				go b.autoDownload(sibling)
			}
		}
	}

	if msg.Text == "" && msg.Kind == "text" && msg.MediaRef == "" && msg.MediaPath == "" {
		// A message with neither text nor an attachment is a protocol artefact:
		// a group update, an expiry change, a typing stub. Storing it would put
		// a blank bubble in the conversation.
		return nil
	}

	return msg
}

// applyAttachment fills in the media fields for one attachment.
func (b *bridge) applyAttachment(msg *messageObj, a attachment) {
	msg.Kind = kindOf(a)
	msg.MediaMime = a.ContentType
	msg.FileName = a.Filename
	msg.FileSize = a.Size
	msg.MediaW = a.Width
	msg.MediaH = a.Height
	msg.MediaRef = a.ID

	// signal-cli has usually already written the file into its own store by the
	// time the notification arrives, so the common case costs no download at
	// all -- the host copies it into the media cache and the image renders.
	if path := attachmentPath(a.ID); path != "" {
		msg.MediaPath = path
	}
}

func kindOf(a attachment) string {
	if a.IsSticker {
		return "sticker"
	}
	if a.IsVoiceNote {
		return "audio"
	}
	switch {
	case strings.HasPrefix(a.ContentType, "image/"):
		return "image"
	case strings.HasPrefix(a.ContentType, "video/"):
		return "video"
	case strings.HasPrefix(a.ContentType, "audio/"):
		return "audio"
	case a.ContentType == "":
		return "document"
	default:
		return "document"
	}
}

// attachmentPath locates an attachment signal-cli already downloaded.
func attachmentPath(id string) string {
	if id == "" {
		return ""
	}
	dir := dataDir()
	if dir == "" {
		return ""
	}
	path := filepath.Join(dir, "attachments", id)
	if info, err := os.Stat(path); err == nil && !info.IsDir() {
		return path
	}
	return ""
}

// ---------------------------------------------------------------- send

func (b *bridge) handleSend(ctx context.Context, c call) {
	var params struct {
		ChatID      string   `json:"chatId"`
		Text        string   `json:"text"`
		ReplyTo     string   `json:"replyTo"`
		Attachments []string `json:"attachments"`
		QuoteText   string   `json:"quoteText"`
		QuoteSender string   `json:"quoteSender"`
	}
	if err := json.Unmarshal(c.Params, &params); err != nil {
		fail(c.ID, "bad_params", "could not read send parameters: %v", err)
		return
	}

	client := b.getRPC()
	account := b.getAccount()
	if client == nil || account == "" {
		fail(c.ID, "not_connected", "Signal is not connected")
		return
	}

	value, isGroup := recipientOf(params.ChatID)
	req := map[string]any{"account": account}
	if isGroup {
		req["groupId"] = value
	} else {
		req["recipient"] = []string{value}
	}
	if params.Text != "" {
		req["message"] = params.Text
	}
	if len(params.Attachments) > 0 {
		req["attachments"] = params.Attachments
	}

	// Quoting needs the original's author and timestamp, which is exactly what
	// the message id was composed from.
	if params.ReplyTo != "" {
		if author, ts, ok := splitMessageID(params.ReplyTo); ok {
			req["quoteTimestamp"] = ts
			req["quoteAuthor"] = author
			// Signal renders the quoted text from what the sender supplies, so
			// omitting it shows the reply attached to an empty bubble.
			if params.QuoteText != "" {
				req["quoteMessage"] = params.QuoteText
			}
		}
	}

	var res struct {
		Timestamp int64 `json:"timestamp"`
	}
	if err := client.callInto("send", req, &res); err != nil {
		fail(c.ID, "send_failed", "%v", err)
		return
	}

	// The host wrote a pending row keyed on the id it invents; returning ours
	// lets it match the delivery receipt that arrives later.
	ok(c.ID, map[string]any{"messageId": messageID(account, tsOrNow(res.Timestamp))})
}

// splitMessageID takes a contract id back apart into author and timestamp.
func splitMessageID(id string) (author string, ts int64, ok bool) {
	// Attachment siblings carry a #n suffix; the original is what Signal knows.
	if hash := strings.IndexByte(id, '#'); hash >= 0 {
		id = id[:hash]
	}
	// The author may itself contain colons, so split on the last one.
	at := strings.LastIndexByte(id, ':')
	if at < 0 {
		return "", 0, false
	}
	parsed, err := strconv.ParseInt(id[at+1:], 10, 64)
	if err != nil {
		return "", 0, false
	}
	return id[:at], parsed, true
}

// ---------------------------------------------------------------- read

func (b *bridge) handleMarkRead(ctx context.Context, c call) {
	var params struct {
		ChatID    string   `json:"chatId"`
		UpTo      int64    `json:"upTo"`
		MessageID string   `json:"messageId"`
		Messages  []string `json:"messageIds"`
	}
	_ = json.Unmarshal(c.Params, &params)

	client := b.getRPC()
	account := b.getAccount()
	if client == nil || account == "" {
		ok(c.ID, nil)
		return
	}

	if !b.settingBool("sendReadReceipts", true) {
		// Reading without telling anyone is a deliberate choice, and the host
		// still clears the unread count locally.
		ok(c.ID, nil)
		return
	}

	// A read receipt goes to the person who sent the message, so it only makes
	// sense for a direct conversation; Signal has no group read receipt.
	value, isGroup := recipientOf(params.ChatID)
	if isGroup {
		ok(c.ID, nil)
		return
	}

	ids := params.Messages
	if params.MessageID != "" {
		ids = append(ids, params.MessageID)
	}

	var timestamps []int64
	seen := map[int64]bool{}
	for _, id := range ids {
		if _, ts, good := splitMessageID(id); good && !seen[ts] {
			seen[ts] = true
			timestamps = append(timestamps, ts)
		}
	}
	// Nothing itemised: fall back to the read position the host tracks.
	if len(timestamps) == 0 && params.UpTo > 0 {
		timestamps = []int64{params.UpTo}
	}
	if len(timestamps) == 0 {
		ok(c.ID, nil)
		return
	}

	err := client.callInto("sendReceipt", map[string]any{
		"account":         account,
		"recipient":       value,
		"targetTimestamp": timestamps,
		"type":            "read",
	}, nil)
	if err != nil {
		// Not a failure worth showing the user: the message is read either way,
		// and only the sender's tick is affected.
		logf("debug", "could not send read receipt: %v", err)
	}
	ok(c.ID, nil)
}

// ---------------------------------------------------------------- revoke

func (b *bridge) handleRevoke(ctx context.Context, c call) {
	var params struct {
		ChatID    string `json:"chatId"`
		MessageID string `json:"messageId"`
	}
	_ = json.Unmarshal(c.Params, &params)

	client := b.getRPC()
	account := b.getAccount()
	if client == nil || account == "" {
		fail(c.ID, "not_connected", "Signal is not connected")
		return
	}

	_, ts, good := splitMessageID(params.MessageID)
	if !good {
		fail(c.ID, "bad_params", "not a Signal message id: %s", params.MessageID)
		return
	}

	value, isGroup := recipientOf(params.ChatID)
	req := map[string]any{"account": account, "targetTimestamp": ts}
	if isGroup {
		req["groupId"] = value
	} else {
		req["recipient"] = []string{value}
	}

	if err := client.callInto("remoteDelete", req, nil); err != nil {
		fail(c.ID, "revoke_failed", "%v", err)
		return
	}
	ok(c.ID, nil)
}

// ---------------------------------------------------------------- media

func (b *bridge) handleFetchMedia(ctx context.Context, c call) {
	var params struct {
		ChatID    string `json:"chatId"`
		MessageID string `json:"messageId"`
		Ref       string `json:"ref"`
	}
	_ = json.Unmarshal(c.Params, &params)

	if params.Ref == "" {
		fail(c.ID, "no_media", "that message has no attachment")
		return
	}

	// Already on disk in signal-cli's store: hand over the path and download
	// nothing.
	if path := attachmentPath(params.Ref); path != "" {
		ok(c.ID, map[string]any{"path": path})
		return
	}

	path, err := b.downloadAttachment(params.ChatID, params.Ref)
	if err != nil {
		fail(c.ID, "fetch_failed", "%v", err)
		return
	}
	ok(c.ID, map[string]any{"path": path})
}

// downloadAttachment asks signal-cli for an attachment it no longer has locally.
func (b *bridge) downloadAttachment(chatID, ref string) (string, error) {
	client := b.getRPC()
	account := b.getAccount()
	if client == nil || account == "" {
		return "", fmt.Errorf("Signal is not connected")
	}

	req := map[string]any{"account": account, "id": ref}
	if value, isGroup := recipientOf(chatID); isGroup {
		req["groupId"] = value
	} else {
		req["recipient"] = value
	}

	var res struct {
		Data     string `json:"data"`
		Filename string `json:"filename"`
	}
	if err := client.callInto("getAttachment", req, &res); err != nil {
		return "", err
	}
	if res.Data == "" {
		return "", fmt.Errorf("attachment is no longer available")
	}

	raw, err := base64.StdEncoding.DecodeString(res.Data)
	if err != nil {
		return "", fmt.Errorf("attachment was not valid base64: %w", err)
	}

	b.mu.RLock()
	dir := b.mediaDir
	b.mu.RUnlock()
	if dir == "" {
		return "", fmt.Errorf("no media directory was configured")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create media dir: %w", err)
	}

	name := res.Filename
	if name == "" {
		name = ref
	}
	// The ref is a server-side id and could be anything; keeping only the base
	// name stops a crafted one from writing outside the media directory.
	path := filepath.Join(dir, filepath.Base(name))
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		return "", fmt.Errorf("write attachment: %w", err)
	}
	return path, nil
}

// autoDownload fetches an attachment in the background and re-emits the message
// once it has landed, so an image appears without the user opening it.
func (b *bridge) autoDownload(msg messageObj) {
	if !b.settingBool("autoDownloadMedia", true) {
		return
	}
	maxMB := int64(b.settingInt("autoDownloadMaxMB", 16))
	if maxMB > 0 && msg.FileSize > maxMB*1024*1024 {
		return
	}

	path, err := b.downloadAttachment(msg.ChatID, msg.MediaRef)
	if err != nil {
		logf("debug", "could not pre-fetch attachment: %v", err)
		return
	}

	msg.MediaPath = path
	emitEvent("message", map[string]any{"message": &msg})
}
