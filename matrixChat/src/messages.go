package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// ---------------------------------------------------------------- inbound

// onMessage converts one timeline message.
//
// Encrypted rooms arrive here already decrypted: the crypto helper unwraps
// m.room.encrypted and re-dispatches the plaintext event.
func (b *bridge) onMessage(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.MessageEventContent)
	if !ok {
		return
	}

	// An edit is not a new message. Matrix sends it as a fresh event pointing at
	// the original; re-emitting under the *original* id makes the host's upsert
	// replace the text in place instead of appending a near-duplicate.
	targetID := evt.ID
	if rel := content.RelatesTo; rel != nil && rel.Type == event.RelReplace && rel.EventID != "" {
		targetID = rel.EventID
		if content.NewContent != nil {
			content = content.NewContent
		}
	}

	msg := b.convert(evt, content, targetID)
	if msg == nil {
		return
	}

	// The event itself, not the edit's target: a read receipt has to name
	// something that actually happened in the timeline.
	b.noteLastEvent(evt.RoomID, evt.ID, evt.Timestamp)

	emitEvent("message", map[string]any{"message": msg})

	if msg.MediaRef != "" && msg.MediaPath == "" {
		go b.autoDownload(*msg)
	}

	// Keep the room's activity line in step so the chat list reorders now
	// rather than after the next full publish.
	chat := b.chatFor(evt.RoomID)
	chat.LastTS = msg.TS
	chat.LastText = previewOf(msg)
	emitEvent("chat", map[string]any{"chat": chat})
}

func (b *bridge) convert(evt *event.Event, content *event.MessageEventContent, msgID id.EventID) *messageObj {
	self := b.selfID()

	msg := &messageObj{
		ID:         string(msgID),
		ChatID:     string(evt.RoomID),
		TS:         evt.Timestamp,
		FromMe:     evt.Sender == self,
		SenderID:   string(evt.Sender),
		SenderName: b.senderName(evt.RoomID, evt.Sender),
		Kind:       "text",
		Text:       content.Body,
	}

	if msg.FromMe {
		// It came back from the homeserver, so it is at least sent. The host
		// ratchets, so this can only move it forward.
		msg.Status = "sent"
	}

	// A reply carries the event it answers. Matrix also prefixes the quoted text
	// into the body as a fallback for old clients; strip it, or every reply
	// shows the original quoted inside it.
	if rel := content.RelatesTo; rel != nil {
		if replyTo := rel.GetReplyTo(); replyTo != "" {
			msg.ReplyTo = string(replyTo)
			msg.Text = stripReplyFallback(msg.Text)
		}
	}

	if content.FormattedBody != "" && content.Format == event.FormatHTML {
		msg.BodyHTML = stripReplyFallbackHTML(content.FormattedBody)
	}

	switch content.MsgType {
	case event.MsgText, event.MsgNotice:
		msg.Kind = "text"
	case event.MsgEmote:
		msg.Kind = "text"
		// An emote is "* Ada waves", not "waves".
		msg.Text = "* " + msg.SenderName + " " + msg.Text
	case event.MsgImage:
		msg.Kind = "image"
	case event.MsgVideo:
		msg.Kind = "video"
	case event.MsgAudio:
		msg.Kind = "audio"
	case event.MsgFile:
		msg.Kind = "document"
	case event.MsgLocation:
		msg.Kind = "location"
	default:
		if evt.Type == event.EventSticker {
			msg.Kind = "sticker"
		}
	}

	b.applyMedia(msg, content)

	if msg.Text == "" && msg.MediaRef == "" && msg.BodyHTML == "" {
		// A message with neither text nor an attachment is a protocol artefact.
		// Storing it would put a blank bubble in the conversation.
		return nil
	}
	return msg
}

// applyMedia fills in the attachment fields.
//
// The mxc:// URI is kept as the ref rather than resolved now: an encrypted room
// sends the file encrypted, and downloading it eagerly for every message would
// pull the whole history's media on first sync.
func (b *bridge) applyMedia(msg *messageObj, content *event.MessageEventContent) {
	url := content.URL
	if content.File != nil && content.File.URL != "" {
		// Encrypted attachment: the URL lives inside the file block, and the
		// keys beside it.
		url = content.File.URL
	}
	if url == "" {
		return
	}

	msg.MediaRef = string(url)
	msg.FileName = content.GetFileName()

	if info := content.Info; info != nil {
		msg.MediaMime = info.MimeType
		msg.FileSize = int64(info.Size)
		msg.MediaW = info.Width
		msg.MediaH = info.Height
		if info.Duration > 0 {
			// Matrix reports milliseconds; the contract wants seconds.
			msg.Duration = info.Duration / 1000
		}
	}

	// The body of a media message is its filename, which would otherwise be
	// shown as the message text as well as the attachment name.
	if msg.FileName != "" && msg.Text == msg.FileName {
		msg.Text = ""
	}
}

// stripReplyFallback removes the quoted original Matrix prepends to a reply.
//
// The fallback is every line of the original prefixed with "> ", then a blank
// line, then the actual reply. Clients that understand m.in_reply_to are
// expected to remove it, and the host renders the quote itself.
func stripReplyFallback(body string) string {
	for strings.HasPrefix(body, "> ") {
		nl := strings.IndexByte(body, '\n')
		if nl < 0 {
			return ""
		}
		body = body[nl+1:]
	}
	return strings.TrimPrefix(body, "\n")
}

func stripReplyFallbackHTML(html string) string {
	// The HTML fallback is a single <mx-reply> element at the start.
	const open, close = "<mx-reply>", "</mx-reply>"
	if !strings.HasPrefix(html, open) {
		return html
	}
	if end := strings.Index(html, close); end >= 0 {
		return strings.TrimSpace(html[end+len(close):])
	}
	return html
}

func (b *bridge) onRedaction(ctx context.Context, evt *event.Event) {
	if evt.Redacts == "" {
		return
	}
	emitEvent("deleted", map[string]any{
		"chatId":    string(evt.RoomID),
		"messageId": string(evt.Redacts),
	})
}

// onReceipt maps Matrix read receipts onto the contract's status ladder, and
// onto our own read position.
//
// Matrix has no per-message delivery receipt: a read receipt names one event and
// means everything up to it has been read. Reporting that event as read is the
// honest translation; the host ratchets, so nothing moves backwards.
//
// Our own receipt is the other half, and the more useful one. It is how Matrix
// records what we have read -- on a phone, in Element, anywhere -- and without
// it a conversation read an hour ago comes back unread here and notifies for
// messages we have already seen.
func (b *bridge) onReceipt(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.ReceiptEventContent)
	if !ok {
		return
	}

	self := b.selfID()
	for eventID, receipts := range *content {
		for receiptType, users := range receipts {
			switch receiptType {
			case event.ReceiptTypeRead, event.ReceiptTypeReadPrivate:
			default:
				continue
			}

			for user, receipt := range users {
				if user == self {
					// A private receipt counts exactly as much as a public one:
					// both are us, having read the room.
					b.noteRead(evt.RoomID, receipt.Timestamp.UnixMilli())
					continue
				}
				// Somebody else read it. Only public receipts say that, and a
				// private one is never anyone else's to see.
				if receiptType == event.ReceiptTypeRead {
					emitEvent("status", map[string]any{
						"messageId": string(eventID),
						"status":    "read",
					})
				}
			}
		}
	}
}

// noteRead records how far this room has been read and tells the host, unless
// it already knew as much.
//
// Never moves backwards: a receipt for an older event -- a client catching up,
// a thread receipt -- must not un-read what has been read since.
func (b *bridge) noteRead(roomID id.RoomID, ts int64) {
	if b.setReadUpTo(roomID, ts) {
		b.touchRoom(roomID)
	}
}

// setReadUpTo records the position and reports whether it moved.
//
// Separate from publishing so the catch-up sync can settle hundreds of rooms
// and then announce them together, rather than a frame per room.
func (b *bridge) setReadUpTo(roomID id.RoomID, ts int64) bool {
	if ts <= 0 {
		// A receipt with no timestamp says nothing about when; guessing "now"
		// here would mark a whole room read on the strength of nothing.
		return false
	}

	b.mu.Lock()
	defer b.mu.Unlock()

	info := b.roomLocked(roomID)
	if ts <= info.ReadUpTo {
		return false
	}
	info.ReadUpTo = ts
	return true
}

// noteLastEvent remembers the newest event a room has shown us.
//
// Only ever forwards: history paging and a resumed sync both deliver older
// events, and a read receipt for one of those would tell our other clients that
// we have read less than we have.
func (b *bridge) noteLastEvent(roomID id.RoomID, eventID id.EventID, ts int64) {
	if eventID == "" || ts <= 0 {
		return
	}

	b.mu.Lock()
	defer b.mu.Unlock()

	info := b.roomLocked(roomID)
	if ts < info.LastEventTS {
		return
	}
	info.LastEventID = eventID
	info.LastEventTS = ts
}

// receiptTarget is the event a read receipt for this room should name, or "".
//
// Empty when there is nothing new to acknowledge: a room whose timeline this
// session has never seen, or one where our own receipt already stands at or
// past the newest event -- which is every reopening of a conversation already
// read, and a request to the homeserver each time it is not checked.
func (b *bridge) receiptTarget(roomID id.RoomID) id.EventID {
	b.mu.RLock()
	defer b.mu.RUnlock()

	info := b.rooms[roomID]
	if info == nil || info.LastEventID == "" {
		return ""
	}
	if info.ReadUpTo >= info.LastEventTS {
		return ""
	}
	return info.LastEventID
}

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
	case "location":
		return "📍 Location"
	case "deleted":
		return "🚫 Deleted message"
	}
	return ""
}

// ---------------------------------------------------------------- outbound

func (b *bridge) handleSend(ctx context.Context, c call) {
	var params struct {
		ChatID      string   `json:"chatId"`
		Text        string   `json:"text"`
		ReplyTo     string   `json:"replyTo"`
		Attachments []string `json:"attachments"`
	}
	if err := json.Unmarshal(c.Params, &params); err != nil {
		fail(c.ID, "bad_params", "could not read send parameters: %v", err)
		return
	}

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return
	}

	roomID := id.RoomID(params.ChatID)

	// An attachment goes as its own event, because a Matrix message carries one
	// file and no caption. Sending several as one event would silently drop all
	// but the first.
	if len(params.Attachments) > 0 {
		var lastID id.EventID
		for _, path := range params.Attachments {
			sent, err := b.sendFile(ctx, client, roomID, path)
			if err != nil {
				fail(c.ID, "send_failed", "%v", err)
				return
			}
			lastID = sent
		}

		if strings.TrimSpace(params.Text) != "" {
			sent, err := b.sendText(ctx, client, roomID, params.Text, params.ReplyTo)
			if err != nil {
				fail(c.ID, "send_failed", "%v", err)
				return
			}
			lastID = sent
		}
		ok(c.ID, map[string]any{"messageId": string(lastID)})
		return
	}

	sent, err := b.sendText(ctx, client, roomID, params.Text, params.ReplyTo)
	if err != nil {
		fail(c.ID, "send_failed", "%v", err)
		return
	}
	ok(c.ID, map[string]any{"messageId": string(sent)})
}

func (b *bridge) sendText(ctx context.Context, client matrixSender, roomID id.RoomID, text, replyTo string) (id.EventID, error) {
	content := &event.MessageEventContent{
		MsgType: event.MsgText,
		Body:    text,
	}
	if replyTo != "" {
		content.RelatesTo = (&event.RelatesTo{}).SetReplyTo(id.EventID(replyTo))
	}

	resp, err := client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		return "", err
	}
	return resp.EventID, nil
}

// sendFile uploads an attachment and sends it as its own event.
func (b *bridge) sendFile(ctx context.Context, client matrixSender, roomID id.RoomID, path string) (id.EventID, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read attachment: %w", err)
	}

	name := filepath.Base(path)
	mime := mimeOf(name)

	uploaded, err := client.UploadBytes(ctx, data, mime)
	if err != nil {
		return "", fmt.Errorf("upload attachment: %w", err)
	}

	content := &event.MessageEventContent{
		MsgType: msgTypeFor(mime),
		Body:    name,
		URL:     uploaded.ContentURI.CUString(),
		Info: &event.FileInfo{
			MimeType: mime,
			Size:     len(data),
		},
	}

	resp, err := client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		return "", err
	}
	return resp.EventID, nil
}

func msgTypeFor(mime string) event.MessageType {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return event.MsgImage
	case strings.HasPrefix(mime, "video/"):
		return event.MsgVideo
	case strings.HasPrefix(mime, "audio/"):
		return event.MsgAudio
	default:
		return event.MsgFile
	}
}

func mimeOf(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".mp4":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".mp3":
		return "audio/mpeg"
	case ".ogg", ".opus":
		return "audio/ogg"
	case ".pdf":
		return "application/pdf"
	case ".txt", ".md":
		return "text/plain"
	default:
		return "application/octet-stream"
	}
}

// ---------------------------------------------------------------- read

// handleMarkRead tells Matrix that this conversation has been read.
//
// The host marks a conversation read at a moment in time and sends no message
// id -- which is what the WhatsApp and Signal bridges are given too. Matrix
// hangs a receipt on an event instead, so the newest event the room has shown
// us is what the receipt names: opening a conversation and reading it to the
// bottom is exactly what every other Matrix client acknowledges that way.
//
// This used to insist on a messageId the host never sends, so it returned
// without doing anything at all -- and a conversation read here stayed unread
// on every other client of the account.
func (b *bridge) handleMarkRead(ctx context.Context, c call) {
	var params struct {
		ChatID    string `json:"chatId"`
		MessageID string `json:"messageId"`
		UpTo      int64  `json:"upTo"`
	}
	_ = json.Unmarshal(c.Params, &params)

	client := b.getClient()
	if client == nil {
		ok(c.ID, nil)
		return
	}

	if !b.settingBool("sendReadReceipts", true) {
		// Reading without telling anyone is a deliberate choice; the host still
		// clears the unread count locally.
		ok(c.ID, nil)
		return
	}

	target := id.EventID(params.MessageID)
	if target == "" {
		target = b.receiptTarget(id.RoomID(params.ChatID))
	}
	if target == "" {
		// Nothing to point a receipt at, or nothing new to acknowledge. The
		// host has cleared its own count either way.
		ok(c.ID, nil)
		return
	}

	if err := client.MarkRead(ctx, id.RoomID(params.ChatID), target); err != nil {
		// Not worth surfacing: the conversation is read either way, and what
		// this affects is what our other clients think.
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

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return
	}

	if _, err := client.RedactEvent(ctx, id.RoomID(params.ChatID), id.EventID(params.MessageID)); err != nil {
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

	path, err := b.download(ctx, params.Ref, params.MessageID)
	if err != nil {
		fail(c.ID, "fetch_failed", "%v", err)
		return
	}
	ok(c.ID, map[string]any{"path": path})
}

// download resolves an mxc:// URI into a file the host can cache.
func (b *bridge) download(ctx context.Context, ref, messageID string) (string, error) {
	client := b.getClient()
	if client == nil {
		return "", fmt.Errorf("Matrix is not connected")
	}

	uri, err := id.ParseContentURI(ref)
	if err != nil {
		return "", fmt.Errorf("not a Matrix media URI: %w", err)
	}

	data, err := client.DownloadBytes(ctx, uri)
	if err != nil {
		return "", fmt.Errorf("download attachment: %w", err)
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

	// Named after the media id, not the filename: two people can send
	// "photo.jpg" and the second would overwrite the first.
	name := uri.FileID
	if name == "" {
		name = strings.NewReplacer("/", "_", ":", "_", "$", "_").Replace(messageID)
	}
	path := filepath.Join(dir, filepath.Base(name))

	if err := os.WriteFile(path, data, 0o600); err != nil {
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

	path, err := b.download(context.Background(), msg.MediaRef, msg.ID)
	if err != nil {
		logf("debug", "could not pre-fetch attachment: %v", err)
		return
	}

	msg.MediaPath = path
	emitEvent("message", map[string]any{"message": &msg})
}

// matrixSender is the slice of the Matrix client that sending needs.
//
// Narrowed to an interface so the send path can be tested without a homeserver,
// which is the only way to exercise it here at all.
type matrixSender interface {
	SendMessageEvent(ctx context.Context, roomID id.RoomID, eventType event.Type, contentJSON interface{}, extra ...mautrix.ReqSendEvent) (*mautrix.RespSendEvent, error)
	UploadBytes(ctx context.Context, data []byte, contentType string) (*mautrix.RespMediaUpload, error)
}
