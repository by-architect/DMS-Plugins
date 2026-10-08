package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto/attachment"
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

	msg, edit := b.messageFor(evt, content)
	if msg == nil {
		return
	}

	// The event itself, not the edit's target: a read receipt has to name
	// something that actually happened in the timeline.
	b.noteLastEvent(evt.RoomID, evt.ID, evt.Timestamp)

	// Only a message that has just arrived goes out on its own, because the
	// single message event is the one the host may notify for. An initial
	// sync's timeline is the last few dozen messages of every room the account
	// is in -- history, held back and sent as a batch once the response has
	// been read through -- and an edit changes a message that is already
	// there. Sent singly, both were announced as news: a fresh sign-in notified
	// for whatever the last half hour held, and a correction arrived as a new
	// message. Neither fetches its attachment ahead of time either.
	if isInitialSync(ctx) {
		b.holdHistory(*msg)
		return
	}
	if edit {
		emitMessages([]messageObj{*msg})
		return
	}

	emitEvent("message", map[string]any{"message": msg})

	if msg.MediaRef != "" && msg.MediaPath == "" {
		b.queueDownload(*msg)
	}

	// Keep the room's activity line in step so the chat list reorders now
	// rather than after the next full publish.
	chat := b.chatFor(evt.RoomID)
	chat.LastTS = msg.TS
	chat.LastText = previewOf(msg)
	emitEvent("chat", map[string]any{"chat": chat})
}

// messageFor converts a timeline message, and reports whether it is an edit.
//
// An edit is not a new message. Matrix sends it as a fresh event pointing at
// the original; re-emitting under the *original* id makes the host's upsert
// replace the text in place instead of appending a near-duplicate.
func (b *bridge) messageFor(evt *event.Event, content *event.MessageEventContent) (*messageObj, bool) {
	targetID := evt.ID
	edit := false
	if rel := content.RelatesTo; rel != nil && rel.Type == event.RelReplace && rel.EventID != "" {
		targetID = rel.EventID
		edit = true
		if content.NewContent != nil {
			content = content.NewContent
		}
	}
	return b.convert(evt, content, targetID), edit
}

// isInitialSync reports whether an event came from a sync with no position to
// start from: the first one a new device makes. mautrix puts the position each
// response was asked from in the context it dispatches with.
func isInitialSync(ctx context.Context) bool {
	since, ok := ctx.Value(mautrix.SyncTokenContextKey).(string)
	return ok && since == ""
}

// holdHistory keeps a message of history back until flushHistory.
func (b *bridge) holdHistory(msg messageObj) {
	b.mu.Lock()
	b.history = append(b.history, msg)
	b.mu.Unlock()
}

// flushHistory sends what holdHistory kept back.
//
// Called once the response it came in has been read through, and before
// anything that names a message by id -- a deletion, a read status -- so the
// message is in the host's store before the reference to it arrives.
func (b *bridge) flushHistory() {
	b.flushMu.Lock()
	defer b.flushMu.Unlock()
	b.flushHeldLocked()
}

// flushHeldLocked sends what is held, for a caller already holding flushMu.
func (b *bridge) flushHeldLocked() {
	b.mu.Lock()
	msgs := b.history
	b.history = nil
	b.mu.Unlock()

	emitMessages(msgs)
}

// emitMessages sends messages as the batch event, which the host stores
// without notifying for any of them.
func emitMessages(msgs []messageObj) {
	const batchSize = 100
	for start := 0; start < len(msgs); start += batchSize {
		end := min(start+batchSize, len(msgs))
		emitEvent("messages", map[string]any{"messages": msgs[start:end]})
	}
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

	// The text is Markdown (the "markdown" capability), so a formatted message
	// is its HTML converted to Markdown: the body is the sender's plain-text
	// fallback, which may have lost the formatting altogether -- a rich text
	// editor or a bridged service writes no Markdown into it. When the HTML
	// converts to nothing, or cannot be converted safely, the body stays.
	if content.FormattedBody != "" && content.Format == event.FormatHTML {
		msg.BodyHTML = stripReplyFallbackHTML(content.FormattedBody)
		if text := markdownFromHTML(msg.BodyHTML); text != "" {
			msg.Text = text
		}
	}

	switch content.MsgType {
	case event.MsgText, event.MsgNotice:
		msg.Kind = "text"
	case event.MsgEmote:
		msg.Kind = "text"
		// An emote is "* Ada waves", not "waves". The star is escaped: a line
		// starting "* " is a list item in Markdown.
		msg.Text = `\* ` + escapeMarkdown(msg.SenderName) + " " + msg.Text
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
// What is needed to fetch the file is kept as the ref rather than resolved now:
// downloading it eagerly for every message would pull the whole history's media
// on first sync.
func (b *bridge) applyMedia(msg *messageObj, content *event.MessageEventContent) {
	switch {
	case content.File != nil && content.File.URL != "":
		// Encrypted attachment: the URL lives inside the file block, beside the
		// key that opens it. Both go in the ref -- the host keeps it opaque and
		// hands it back to fetchMedia as it was -- because a ref of the URL
		// alone fetched only the ciphertext, and every attachment in an
		// encrypted room arrived as noise. See parseMediaRef.
		ref, err := json.Marshal(content.File)
		if err != nil {
			return
		}
		msg.MediaRef = string(ref)
	case content.URL != "":
		msg.MediaRef = string(content.URL)
	default:
		return
	}

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
	// Under the lock a decrypted message goes out under, so a message still
	// waiting for its key is either filled in before this deletion or never:
	// filled in after it, it would come back. See deliverRecovered.
	b.flushMu.Lock()
	defer b.flushMu.Unlock()
	b.forgetWaiting(evt.Redacts)

	// Anything held back as history first, so the message is stored before
	// the deletion that names it arrives.
	b.flushHeldLocked()
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
					// After anything held back as history: a status for a
					// message not yet stored is lost.
					b.flushHistory()
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

	// An encrypted room, with encryption not working on this device. mautrix
	// encrypts only when it holds a crypto helper; without one it sends in
	// plain text and says nothing -- into a room whose members expect nothing
	// to leave a device readable. Refusing is the only honest answer.
	encrypted, canEncrypt := b.roomEncryption(ctx, client, roomID)
	if encrypted && !canEncrypt {
		fail(c.ID, "no_encryption", "This room is end-to-end encrypted and encryption is not working on this device, so nothing was sent.")
		return
	}

	// An attachment goes as its own event, because a Matrix message carries one
	// file. Sending several as one event would silently drop all but the first.
	//
	// The caption and the reply ride in the first, in the same event: the host
	// recorded them on that one row. Sent as an event of its own, the caption
	// came back as a second message, and the row the host had kept for it --
	// which carried the attachment -- showed the file a second time.
	if len(params.Attachments) > 0 {
		var first id.EventID
		for i, path := range params.Attachments {
			caption, replyTo := "", ""
			if i == 0 {
				caption, replyTo = params.Text, params.ReplyTo
			}
			sent, err := b.sendFile(ctx, client, roomID, path, caption, replyTo, encrypted)
			if err != nil {
				fail(c.ID, "send_failed", "%v", err)
				return
			}
			if i == 0 {
				first = sent
			}
		}
		ok(c.ID, map[string]any{"messageId": string(first)})
		return
	}

	sent, err := b.sendText(ctx, client, roomID, params.Text, params.ReplyTo)
	if err != nil {
		fail(c.ID, "send_failed", "%v", err)
		return
	}
	ok(c.ID, map[string]any{"messageId": string(sent)})
}

// sendText sends what was typed in the composer: Markdown, which goes as the
// body with its HTML rendering beside it when it formats anything (setText).
func (b *bridge) sendText(ctx context.Context, client matrixSender, roomID id.RoomID, text, replyTo string) (id.EventID, error) {
	content := &event.MessageEventContent{MsgType: event.MsgText}
	setText(content, text)
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
//
// A caption goes in the same event, the way Matrix 1.10 carries one: the body
// is the caption and filename names the file. A caption is Markdown like any
// message, and carries its HTML the same way. In an encrypted room the file
// itself is encrypted before it is uploaded, with its key inside the event --
// which is encrypted in turn -- the way every Matrix client sends one.
// Uploaded as it was, the homeserver kept a readable copy of every attachment
// sent into a room that nobody else could read.
func (b *bridge) sendFile(ctx context.Context, client matrixSender, roomID id.RoomID, path, caption, replyTo string, encrypted bool) (id.EventID, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read attachment: %w", err)
	}

	name := filepath.Base(path)
	mime := mimeOf(name)

	content := &event.MessageEventContent{
		MsgType:  msgTypeFor(mime),
		Body:     name,
		FileName: name,
		Info: &event.FileInfo{
			MimeType: mime,
			Size:     len(data),
		},
	}
	if strings.TrimSpace(caption) != "" {
		setText(content, caption)
	}
	if replyTo != "" {
		content.RelatesTo = (&event.RelatesTo{}).SetReplyTo(id.EventID(replyTo))
	}

	uploadMime := mime
	if encrypted {
		content.File = &event.EncryptedFileInfo{EncryptedFile: *attachment.NewEncryptedFile()}
		content.File.EncryptInPlace(data)
		// What is uploaded is ciphertext; its real type travels in the info.
		uploadMime = "application/octet-stream"
	}

	uploaded, err := client.UploadBytes(ctx, data, uploadMime)
	if err != nil {
		return "", fmt.Errorf("upload attachment: %w", err)
	}

	if content.File != nil {
		content.File.URL = uploaded.ContentURI.CUString()
	} else {
		content.URL = uploaded.ContentURI.CUString()
	}

	resp, err := client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		return "", err
	}
	return resp.EventID, nil
}

// roomEncryption reports whether a room is end-to-end encrypted, and whether
// this device can encrypt at the moment.
//
// The room cache answers first: it is fed by the same state events as
// mautrix's own store, and it survives an encryption store that failed to
// open -- exactly when the question matters. mautrix's store is asked as well
// once encryption is running, since that is what decides whether mautrix
// encrypts the event itself.
func (b *bridge) roomEncryption(ctx context.Context, client *mautrix.Client, roomID id.RoomID) (encrypted, canEncrypt bool) {
	b.mu.RLock()
	canEncrypt = b.crypto != nil
	if info := b.rooms[roomID]; info != nil {
		encrypted = info.Encrypted
	}
	b.mu.RUnlock()

	if !encrypted && canEncrypt && client.StateStore != nil {
		encrypted, _ = client.StateStore.IsEncrypted(ctx, roomID)
	}
	return encrypted, canEncrypt
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

	ref, err := b.keyedRef(ctx, id.RoomID(params.ChatID), id.EventID(params.MessageID), params.Ref)
	if err != nil {
		fail(c.ID, "fetch_failed", "%v", err)
		return
	}

	// No limit: the user asked for this one. It is streamed to disk, so a
	// large file costs disk space rather than its size in memory.
	path, err := b.download(ctx, ref, params.MessageID, 0)
	if err != nil {
		fail(c.ID, "fetch_failed", "%v", err)
		return
	}
	ok(c.ID, map[string]any{"path": path})
}

// errTooLarge is an attachment bigger than the limit it was fetched under.
var errTooLarge = errors.New("attachment is larger than the auto-download limit")

// parseMediaRef turns a ref from applyMedia back into what to download, and
// the key to open it with when it came from an encrypted room.
func parseMediaRef(ref string) (id.ContentURI, *event.EncryptedFileInfo, error) {
	if strings.HasPrefix(ref, "{") {
		var file event.EncryptedFileInfo
		if err := json.Unmarshal([]byte(ref), &file); err != nil {
			return id.ContentURI{}, nil, fmt.Errorf("unreadable attachment reference: %w", err)
		}
		uri, err := file.URL.Parse()
		if err != nil {
			return id.ContentURI{}, nil, fmt.Errorf("not a Matrix media URI: %w", err)
		}
		return uri, &file, nil
	}

	uri, err := id.ParseContentURI(ref)
	if err != nil {
		return id.ContentURI{}, nil, fmt.Errorf("not a Matrix media URI: %w", err)
	}
	return uri, nil, nil
}

// keyedRef finds the key for an attachment whose ref was stored without one.
//
// Before refs carried the encrypted file's key, an attachment in an encrypted
// room was stored as its bare URL: fetched, it was the ciphertext, and nothing
// to open it with -- so it opened as noise. The key was in the message all
// along, and the message id is the event id: fetching the event again, and
// decrypting it, finds the key where it always was.
//
// The event is fetched whatever the room is thought to be, since it is the
// event that knows whether it was encrypted. When it cannot be fetched, the
// plain download is still tried in a room not known to be encrypted; in one
// that is, the plain download is the noise this replaces.
func (b *bridge) keyedRef(ctx context.Context, roomID id.RoomID, eventID id.EventID, ref string) (string, error) {
	client := b.getClient()
	if client == nil {
		// The download says that it is not connected.
		return ref, nil
	}
	encrypted, _ := b.roomEncryption(ctx, client, roomID)

	var dec eventDecrypter
	if helper := b.currentCrypto(); helper != nil {
		dec = helper
	}
	return legacyRef(ctx, client, dec, encrypted, roomID, eventID, ref)
}

// legacyRef is keyedRef with what it needs passed in.
func legacyRef(ctx context.Context, src eventSource, dec eventDecrypter, encrypted bool, roomID id.RoomID, eventID id.EventID, ref string) (string, error) {
	uri, file, err := parseMediaRef(ref)
	if err != nil || file != nil || roomID == "" || !strings.HasPrefix(string(eventID), "$") {
		// Unreadable, already keyed, or not a Matrix event: the download
		// takes it as it is.
		return ref, nil
	}

	evt, err := fetchEvent(ctx, src, dec, roomID, eventID)
	switch {
	case errors.Is(err, errNotDecrypted):
		return "", fmt.Errorf("this attachment is encrypted, and its message cannot be decrypted on this device yet: %w", err)
	case err != nil && encrypted:
		return "", fmt.Errorf("this attachment is encrypted, and its message could not be read to find the key: %w", err)
	case err != nil:
		return ref, nil
	}

	key, found := attachmentIn(evt, uri)
	switch {
	case key != nil:
		keyed, err := json.Marshal(key)
		if err != nil {
			return "", fmt.Errorf("unusable attachment key: %w", err)
		}
		return string(keyed), nil
	case found:
		// Sent unencrypted -- a sticker, or a message from before the room
		// was encrypted -- so the plain download is the right one.
		return ref, nil
	case encrypted || evt.Mautrix.WasEncrypted:
		return "", fmt.Errorf("this attachment is encrypted, and its key is not in the message it came with")
	}
	return ref, nil
}

// attachmentIn finds the attachment a ref names in the message it came from:
// its encrypted file info when it was encrypted, and whether the message
// carries it at all. An edit may have put it in the replacement content.
func attachmentIn(evt *event.Event, uri id.ContentURI) (*event.EncryptedFileInfo, bool) {
	content, ok := evt.Content.Parsed.(*event.MessageEventContent)
	if !ok {
		return nil, false
	}
	for _, c := range []*event.MessageEventContent{content, content.NewContent} {
		if c == nil {
			continue
		}
		if c.File != nil {
			if fileURI, err := c.File.URL.Parse(); err == nil && fileURI == uri {
				return c.File, true
			}
		}
		if c.URL != "" {
			if plainURI, err := c.URL.Parse(); err == nil && plainURI == uri {
				return nil, true
			}
		}
	}
	return nil, false
}

// download resolves an attachment ref into a file the host can cache.
//
// limit caps how much is read, zero meaning no cap. DownloadBytes read the
// whole file into memory with no ceiling at all, so an attachment that claimed
// no size -- which the auto-download limit could not check -- was taken in
// whole, however large.
func (b *bridge) download(ctx context.Context, ref, messageID string, limit int64) (string, error) {
	client := b.getClient()
	if client == nil {
		return "", fmt.Errorf("Matrix is not connected")
	}

	uri, file, err := parseMediaRef(ref)
	if err != nil {
		return "", err
	}

	b.mu.RLock()
	dir := b.mediaDir
	b.mu.RUnlock()
	if dir == "" {
		return "", fmt.Errorf("no media directory was configured")
	}

	resp, err := client.Download(ctx, uri)
	if err != nil {
		return "", fmt.Errorf("download attachment: %w", err)
	}
	defer resp.Body.Close()

	if limit > 0 && resp.ContentLength > limit {
		return "", errTooLarge
	}

	// Named after the media id, not the filename: two people can send
	// "photo.jpg" and the second would overwrite the first.
	name := uri.FileID
	if name == "" {
		name = strings.NewReplacer("/", "_", ":", "_", "$", "_").Replace(messageID)
	}
	return saveAttachment(dir, name, resp.Body, file, limit)
}

// saveAttachment writes a downloaded attachment into dir, decrypting it on the
// way when it came from an encrypted room.
//
// Written under a temporary name and renamed into place, so the host is never
// pointed at half a file -- nor at one whose hash did not match, which is not
// the file that was sent.
func saveAttachment(dir, name string, body io.Reader, file *event.EncryptedFileInfo, limit int64) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create media dir: %w", err)
	}

	if limit > 0 {
		// One byte over is enough to know it is too large.
		body = io.LimitReader(body, limit+1)
	}

	var decrypting io.ReadSeekCloser
	if file != nil {
		// Checked before reading anything: a key that cannot be used will not
		// open the file afterwards either, and mautrix's decrypting reader
		// assumes this has already been done.
		if err := file.PrepareForDecryption(); err != nil {
			return "", fmt.Errorf("cannot decrypt this attachment: %w", err)
		}
		decrypting = file.DecryptStream(body)
		body = decrypting
	}

	tmp, err := os.CreateTemp(dir, ".matrix-download-*")
	if err != nil {
		return "", fmt.Errorf("write attachment: %w", err)
	}

	written, err := io.Copy(tmp, body)
	if err == nil && limit > 0 && written > limit {
		err = errTooLarge
	}
	if err == nil && decrypting != nil {
		// Close is where the hash is checked, once everything has been read.
		err = decrypting.Close()
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(tmp.Name())
		return "", fmt.Errorf("write attachment: %w", err)
	}

	path := filepath.Join(dir, filepath.Base(name))
	if err := os.Rename(tmp.Name(), path); err != nil {
		_ = os.Remove(tmp.Name())
		return "", fmt.Errorf("write attachment: %w", err)
	}
	return path, nil
}

const (
	// How many attachments are fetched at once, and how many may wait. A sync
	// after a day away can carry hundreds: a goroutine for each started every
	// download at once, and the homeserver rate-limited the lot.
	downloadWorkers = 4
	downloadQueue   = 64
)

// queueDownload hands an arriving attachment to the background downloads, if
// the settings want it fetched ahead of time.
func (b *bridge) queueDownload(msg messageObj) {
	if !b.settingBool("autoDownloadMedia", true) {
		return
	}
	if limit := b.autoDownloadLimit(); limit > 0 && msg.FileSize > limit {
		return
	}

	b.downloadsOnce.Do(func() {
		b.downloads = make(chan messageObj, downloadQueue)
		for range downloadWorkers {
			go func() {
				for queued := range b.downloads {
					b.autoDownload(queued)
				}
			}()
		}
	})

	select {
	case b.downloads <- msg:
	default:
		// Full: more arrived at once than is worth fetching ahead of time.
		// These are fetched when they are opened instead.
	}
}

// autoDownloadLimit is the largest attachment fetched without being asked
// for, in bytes. Zero is no limit.
func (b *bridge) autoDownloadLimit() int64 {
	maxMB := int64(b.settingInt("autoDownloadMaxMB", 16))
	if maxMB <= 0 {
		return 0
	}
	return maxMB * 1024 * 1024
}

// autoDownload fetches an attachment in the background and re-states the
// message once it has landed, so an image appears without the user opening it.
func (b *bridge) autoDownload(msg messageObj) {
	// The limit is enforced on the download as well as checked against the
	// size the sender stated, which may be missing or wrong.
	path, err := b.download(context.Background(), msg.MediaRef, msg.ID, b.autoDownloadLimit())
	if err != nil {
		logf("debug", "could not pre-fetch attachment: %v", err)
		return
	}

	msg.MediaPath = path
	// As a batch: the message went out when it arrived, and this only adds
	// where its file now is. Sent as a message of its own it was a second
	// arrival, and the host notified for the same message twice.
	emitMessages([]messageObj{msg})
}

// matrixSender is the slice of the Matrix client that sending needs.
//
// Narrowed to an interface so the send path can be tested without a homeserver,
// which is the only way to exercise it here at all.
type matrixSender interface {
	SendMessageEvent(ctx context.Context, roomID id.RoomID, eventType event.Type, contentJSON interface{}, extra ...mautrix.ReqSendEvent) (*mautrix.RespSendEvent, error)
	UploadBytes(ctx context.Context, data []byte, contentType string) (*mautrix.RespMediaUpload, error)
}
