package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// maxUploadBytes is WhatsApp's practical attachment ceiling.
const maxUploadBytes = 100 << 20

// uploadTimeout bounds a single send; large videos are slow but not unbounded.
const uploadTimeout = 5 * time.Minute

// mediaHandle is what a later fetchMedia needs to download an attachment.
type mediaHandle struct {
	msg  *waE2E.Message
	mime string
}

// convertLive converts an incoming or echoed message event.
func (b *bridge) convertLive(info types.MessageInfo, wa *waE2E.Message) *messageObj {
	if wa == nil {
		return nil
	}

	msg := &messageObj{
		ID:       info.ID,
		ChatID:   info.Chat.String(),
		TS:       tsMillis(info.Timestamp),
		FromMe:   info.IsFromMe,
		SenderID: info.Sender.String(),
		Status:   "delivered",
	}

	if info.IsGroup && !info.IsFromMe {
		msg.SenderName = b.contactName(info.Sender, info.PushName)
	}

	b.fillContent(msg, wa)
	if msg.Kind == "" {
		return nil
	}
	return msg
}

// convertWebMessage converts a history-sync row, which arrives in a different
// wrapper than live messages do.
func (b *bridge) convertWebMessage(chat types.JID, web *waWeb.WebMessageInfo) *messageObj {
	if web == nil || web.GetMessage() == nil {
		return nil
	}

	key := web.GetKey()
	msg := &messageObj{
		ID:     key.GetID(),
		ChatID: chat.String(),
		TS:     int64(web.GetMessageTimestamp()) * 1000,
		FromMe: key.GetFromMe(),
		Status: "delivered",
	}

	// History sync marks messages read that the account has already seen.
	if web.GetStatus() >= waWeb.WebMessageInfo_READ {
		msg.Status = "read"
	}

	if participant := key.GetParticipant(); participant != "" && !msg.FromMe {
		if jid, err := types.ParseJID(participant); err == nil {
			msg.SenderID = jid.String()
			msg.SenderName = b.contactName(jid, web.GetPushName())
		}
	}

	b.fillContent(msg, web.GetMessage())
	if msg.Kind == "" {
		return nil
	}
	return msg
}

// fillContent maps a WhatsApp message body onto kind, text and media fields.
//
// Media is described but never downloaded here: a thumbnail goes inline and the
// full attachment is left behind a ref, so a history sync costs no bandwidth
// beyond what WhatsApp already pushed.
func (b *bridge) fillContent(msg *messageObj, wa *waE2E.Message) {
	// Unwrap the containers WhatsApp uses for ephemeral and view-once media.
	if e := wa.GetEphemeralMessage(); e.GetMessage() != nil {
		wa = e.GetMessage()
	}
	if v := wa.GetViewOnceMessage(); v.GetMessage() != nil {
		wa = v.GetMessage()
	}
	if v := wa.GetViewOnceMessageV2(); v.GetMessage() != nil {
		wa = v.GetMessage()
	}
	if d := wa.GetDocumentWithCaptionMessage(); d.GetMessage() != nil {
		wa = d.GetMessage()
	}

	switch {
	case wa.GetConversation() != "":
		msg.Kind = "text"
		msg.Text = wa.GetConversation()

	case wa.GetExtendedTextMessage() != nil:
		ext := wa.GetExtendedTextMessage()
		msg.Kind = "text"
		msg.Text = ext.GetText()
		msg.ReplyTo = ext.GetContextInfo().GetStanzaID()

	case wa.GetImageMessage() != nil:
		m := wa.GetImageMessage()
		msg.Kind = "image"
		msg.Text = m.GetCaption()
		msg.MediaMime = m.GetMimetype()
		msg.MediaW = int(m.GetWidth())
		msg.MediaH = int(m.GetHeight())
		msg.FileSize = int64(m.GetFileLength())
		msg.ReplyTo = m.GetContextInfo().GetStanzaID()
		b.attachThumbnail(msg, m.GetJPEGThumbnail())
		b.rememberMedia(msg, wa, m.GetMimetype())

	case wa.GetVideoMessage() != nil:
		m := wa.GetVideoMessage()
		msg.Kind = "video"
		msg.Text = m.GetCaption()
		msg.MediaMime = m.GetMimetype()
		msg.MediaW = int(m.GetWidth())
		msg.MediaH = int(m.GetHeight())
		msg.FileSize = int64(m.GetFileLength())
		msg.Duration = int(m.GetSeconds())
		msg.ReplyTo = m.GetContextInfo().GetStanzaID()
		b.attachThumbnail(msg, m.GetJPEGThumbnail())
		b.rememberMedia(msg, wa, m.GetMimetype())

	case wa.GetAudioMessage() != nil:
		m := wa.GetAudioMessage()
		msg.Kind = "audio"
		msg.MediaMime = m.GetMimetype()
		msg.FileSize = int64(m.GetFileLength())
		msg.Duration = int(m.GetSeconds())
		msg.ReplyTo = m.GetContextInfo().GetStanzaID()
		b.rememberMedia(msg, wa, m.GetMimetype())

	case wa.GetDocumentMessage() != nil:
		m := wa.GetDocumentMessage()
		msg.Kind = "document"
		msg.Text = m.GetCaption()
		msg.FileName = m.GetFileName()
		msg.MediaMime = m.GetMimetype()
		msg.FileSize = int64(m.GetFileLength())
		msg.ReplyTo = m.GetContextInfo().GetStanzaID()
		b.attachThumbnail(msg, m.GetJPEGThumbnail())
		b.rememberMedia(msg, wa, m.GetMimetype())

	case wa.GetStickerMessage() != nil:
		m := wa.GetStickerMessage()
		msg.Kind = "sticker"
		msg.MediaMime = m.GetMimetype()
		msg.MediaW = int(m.GetWidth())
		msg.MediaH = int(m.GetHeight())
		msg.ReplyTo = m.GetContextInfo().GetStanzaID()
		b.rememberMedia(msg, wa, m.GetMimetype())

	case wa.GetLocationMessage() != nil:
		m := wa.GetLocationMessage()
		msg.Kind = "location"
		msg.Text = fmt.Sprintf("%.5f, %.5f", m.GetDegreesLatitude(), m.GetDegreesLongitude())
		if name := m.GetName(); name != "" {
			msg.Text = name + " (" + msg.Text + ")"
		}

	case wa.GetContactMessage() != nil:
		msg.Kind = "contact"
		msg.Text = wa.GetContactMessage().GetDisplayName()

	case wa.GetProtocolMessage() != nil:
		p := wa.GetProtocolMessage()
		if p.GetType() == waE2E.ProtocolMessage_REVOKE {
			// A deletion refers to another message; report it as such rather
			// than as a message in its own right.
			if key := p.GetKey(); key != nil {
				emitEvent("deleted", map[string]any{
					"chatId":    msg.ChatID,
					"messageId": key.GetID(),
				})
			}
		}
		// Protocol traffic is not a message; drop it.
		return

	case wa.GetReactionMessage() != nil:
		// Reactions are not modelled by the contract yet.
		return

	default:
		msg.Kind = "unsupported"
	}
}

// attachThumbnail inlines a preview so a bubble renders before the real
// attachment is ever downloaded. Only WhatsApp's own embedded thumbnail, which
// costs no network.
func (b *bridge) attachThumbnail(msg *messageObj, thumb []byte) {
	if len(thumb) == 0 || len(thumb) > 64*1024 {
		return
	}
	msg.MediaBytes = base64.StdEncoding.EncodeToString(thumb)
	if msg.MediaMime == "" {
		msg.MediaMime = "image/jpeg"
	}
}

// rememberMedia keeps what a later fetchMedia needs, and sets the ref that
// brings the host back here when the user opens the attachment.
func (b *bridge) rememberMedia(msg *messageObj, wa *waE2E.Message, mime string) {
	msg.MediaRef = msg.ID

	b.mu.Lock()
	defer b.mu.Unlock()

	if _, exists := b.pendingMedia[msg.ID]; !exists {
		b.mediaOrder = append(b.mediaOrder, msg.ID)
	}
	b.pendingMedia[msg.ID] = mediaHandle{msg: proto.Clone(wa).(*waE2E.Message), mime: mime}

	// Bounded: this is a cache, not storage. Storage is the host's job.
	for len(b.mediaOrder) > mediaCacheSize {
		oldest := b.mediaOrder[0]
		b.mediaOrder = b.mediaOrder[1:]
		delete(b.pendingMedia, oldest)
	}
}

// ---------------------------------------------------------------- auto-download

// defaultAutoDownloadMaxMB is the ceiling on unattended downloads. A long video
// arriving unannounced should not silently consume the connection.
const defaultAutoDownloadMaxMB = 16

// autoDownload fetches an attachment as its message arrives and re-emits the
// message with a real path.
//
// Re-emitting rather than delaying the original: the message appears instantly
// with WhatsApp's embedded thumbnail, and the full image replaces it when ready.
// The host upserts on message id and keeps media it already has, so the second
// emission fills in the path without duplicating anything.
func (b *bridge) autoDownload(msg messageObj) {
	if !b.settingBool("autoDownloadMedia", true) {
		return
	}

	limit := int64(b.settingInt("autoDownloadMaxMB", defaultAutoDownloadMaxMB)) << 20
	if limit > 0 && msg.FileSize > limit {
		logf("debug", "skipping auto-download of %s (%d bytes, over the limit)", msg.ID, msg.FileSize)
		return
	}

	b.mu.RLock()
	handle, found := b.pendingMedia[msg.ID]
	dir := b.mediaDir
	b.mu.RUnlock()

	if !found || dir == "" {
		return
	}

	downloadable := downloadableOf(handle.msg)
	if downloadable == nil {
		return
	}

	client := b.getClient()
	if client == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), uploadTimeout)
	defer cancel()

	data, err := client.Download(ctx, downloadable)
	if err != nil {
		// Not fatal: the attachment stays fetchable on demand.
		logf("debug", "auto-download failed for %s: %v", msg.ID, err)
		return
	}

	path, err := b.writeMedia(dir, msg.ID, handle.mime, data)
	if err != nil {
		logf("warn", "could not store auto-downloaded media: %v", err)
		return
	}

	// Only the fields that changed; everything else the host already has.
	emitEvent("message", map[string]any{"message": messageObj{
		ID:        msg.ID,
		ChatID:    msg.ChatID,
		TS:        msg.TS,
		FromMe:    msg.FromMe,
		Kind:      msg.Kind,
		MediaPath: path,
		MediaMime: handle.mime,
	}})
}

// writeMedia stores attachment bytes in the directory the host provided.
func (b *bridge) writeMedia(dir, messageID, mime string, data []byte) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create media directory: %w", err)
	}

	path := filepath.Join(dir, sanitize(messageID)+extensionFor(mime))
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", fmt.Errorf("write attachment: %w", err)
	}
	return path, nil
}

// ---------------------------------------------------------------- fetchMedia

func (b *bridge) handleFetchMedia(ctx context.Context, c call) {
	var params struct {
		ChatID    string `json:"chatId"`
		MessageID string `json:"messageId"`
		Ref       string `json:"ref"`
	}
	if err := json.Unmarshal(c.Params, &params); err != nil {
		fail(c.ID, "bad_request", "%v", err)
		return
	}

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "not connected to WhatsApp")
		return
	}

	b.mu.RLock()
	handle, found := b.pendingMedia[params.MessageID]
	b.mu.RUnlock()

	if !found {
		fail(c.ID, "no_media", "this attachment is no longer available; reopen the conversation to refresh it")
		return
	}

	downloadable := downloadableOf(handle.msg)
	if downloadable == nil {
		fail(c.ID, "no_media", "message carries no downloadable attachment")
		return
	}

	data, err := client.Download(ctx, downloadable)
	if err != nil {
		fail(c.ID, "fetch_failed", "%v", err)
		return
	}

	// Write into the directory the host gave us rather than returning bytes:
	// a full-resolution photo inline would stall every message behind it.
	b.mu.RLock()
	dir := b.mediaDir
	b.mu.RUnlock()

	if dir == "" {
		ok(c.ID, map[string]any{
			"bytes": base64.StdEncoding.EncodeToString(data),
			"mime":  handle.mime,
		})
		return
	}

	path, err := b.writeMedia(dir, params.MessageID, handle.mime, data)
	if err != nil {
		fail(c.ID, "fetch_failed", "%v", err)
		return
	}

	ok(c.ID, map[string]any{"path": path, "mime": handle.mime})
}

// downloadableOf picks whichever body of a message whatsmeow can download.
func downloadableOf(wa *waE2E.Message) whatsmeow.DownloadableMessage {
	switch {
	case wa.GetImageMessage() != nil:
		return wa.GetImageMessage()
	case wa.GetVideoMessage() != nil:
		return wa.GetVideoMessage()
	case wa.GetAudioMessage() != nil:
		return wa.GetAudioMessage()
	case wa.GetDocumentMessage() != nil:
		return wa.GetDocumentMessage()
	case wa.GetStickerMessage() != nil:
		return wa.GetStickerMessage()
	}
	return nil
}

// ---------------------------------------------------------------- send

func (b *bridge) handleSend(ctx context.Context, c call) {
	var params struct {
		ChatID      string   `json:"chatId"`
		Text        string   `json:"text"`
		ReplyTo     string   `json:"replyTo"`
		Attachments []string `json:"attachments"`
	}
	if err := json.Unmarshal(c.Params, &params); err != nil {
		fail(c.ID, "bad_request", "%v", err)
		return
	}

	client := b.getClient()
	if client == nil || !client.IsLoggedIn() {
		fail(c.ID, "not_logged_in", "not signed in to WhatsApp")
		return
	}

	to, err := types.ParseJID(params.ChatID)
	if err != nil {
		fail(c.ID, "bad_request", "not a valid conversation id: %v", err)
		return
	}

	sendCtx, cancel := context.WithTimeout(ctx, uploadTimeout)
	defer cancel()

	if len(params.Attachments) > 0 {
		b.sendAttachments(sendCtx, c, client, to, params.Attachments, params.Text)
		return
	}

	if strings.TrimSpace(params.Text) == "" {
		fail(c.ID, "bad_request", "nothing to send")
		return
	}

	msg := buildTextMessage(params.Text, params.ReplyTo, to)
	resp, err := client.SendMessage(sendCtx, to, msg)
	if err != nil {
		fail(c.ID, "send_failed", "%v", err)
		return
	}

	ok(c.ID, map[string]any{"messageId": resp.ID})
}

// buildTextMessage produces a plain message, or an extended one when it is a
// reply, since only the extended form carries reply context.
func buildTextMessage(text, replyTo string, chat types.JID) *waE2E.Message {
	if replyTo == "" {
		return &waE2E.Message{Conversation: proto.String(text)}
	}

	return &waE2E.Message{
		ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: proto.String(text),
			ContextInfo: &waE2E.ContextInfo{
				StanzaID:      proto.String(replyTo),
				Participant:   proto.String(chat.String()),
				QuotedMessage: &waE2E.Message{Conversation: proto.String("")},
			},
		},
	}
}

// sendAttachments uploads and sends each file, with the caption on the first.
func (b *bridge) sendAttachments(ctx context.Context, c call, client *whatsmeow.Client, to types.JID, paths []string, caption string) {
	var lastID string

	for i, path := range paths {
		data, mime, err := readAttachment(path)
		if err != nil {
			fail(c.ID, "send_failed", "%v", err)
			return
		}

		kind := kindForMime(mime)

		mediaType, err := uploadTypeFor(kind)
		if err != nil {
			fail(c.ID, "send_failed", "%v", err)
			return
		}

		uploaded, err := client.Upload(ctx, data, mediaType)
		if err != nil {
			fail(c.ID, "send_failed", "upload failed: %v", err)
			return
		}

		// Only the first attachment carries the caption, matching what other
		// WhatsApp clients do with a multi-file send.
		text := ""
		if i == 0 {
			text = caption
		}

		msg := buildAttachmentMessage(kind, uploaded, data, mime, filepath.Base(path), text)
		resp, err := client.SendMessage(ctx, to, msg)
		if err != nil {
			fail(c.ID, "send_failed", "%v", err)
			return
		}
		lastID = resp.ID
	}

	ok(c.ID, map[string]any{"messageId": lastID})
}

func buildAttachmentMessage(kind string, up whatsmeow.UploadResponse, data []byte, mime, fileName, caption string) *waE2E.Message {
	length := uint64(len(data))

	switch kind {
	case "image":
		return &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			Caption:       proto.String(caption),
			Mimetype:      proto.String(mime),
			URL:           proto.String(up.URL),
			DirectPath:    proto.String(up.DirectPath),
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    proto.Uint64(length),
		}}
	case "video":
		return &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
			Caption:       proto.String(caption),
			Mimetype:      proto.String(mime),
			URL:           proto.String(up.URL),
			DirectPath:    proto.String(up.DirectPath),
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    proto.Uint64(length),
		}}
	case "audio":
		return &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			Mimetype:      proto.String(mime),
			URL:           proto.String(up.URL),
			DirectPath:    proto.String(up.DirectPath),
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    proto.Uint64(length),
		}}
	default:
		return &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
			Caption:       proto.String(caption),
			FileName:      proto.String(fileName),
			Mimetype:      proto.String(mime),
			URL:           proto.String(up.URL),
			DirectPath:    proto.String(up.DirectPath),
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    proto.Uint64(length),
		}}
	}
}

func uploadTypeFor(kind string) (whatsmeow.MediaType, error) {
	switch kind {
	case "image":
		return whatsmeow.MediaImage, nil
	case "video":
		return whatsmeow.MediaVideo, nil
	case "audio":
		return whatsmeow.MediaAudio, nil
	case "document":
		return whatsmeow.MediaDocument, nil
	}
	return whatsmeow.MediaDocument, fmt.Errorf("cannot send %q", kind)
}

func readAttachment(path string) ([]byte, string, error) {
	path = expandPath(path)

	info, err := os.Stat(path)
	if err != nil {
		return nil, "", fmt.Errorf("cannot read %s: %w", filepath.Base(path), err)
	}
	if info.Size() > maxUploadBytes {
		return nil, "", fmt.Errorf("%s is larger than WhatsApp's 100 MB limit", filepath.Base(path))
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("cannot read %s: %w", filepath.Base(path), err)
	}

	mime := mimeForExtension(filepath.Ext(path))
	if mime == "" {
		mime = http.DetectContentType(data)
	}
	return data, mime, nil
}

// kindForMime decides how WhatsApp should carry a file.
func kindForMime(mime string) string {
	// WebP is treated as a sticker by WhatsApp, which silently drops the
	// caption, so it goes as a document instead.
	if strings.HasPrefix(mime, "image/webp") {
		return "document"
	}

	switch {
	case strings.HasPrefix(mime, "image/"):
		return "image"
	case strings.HasPrefix(mime, "video/"):
		return "video"
	case strings.HasPrefix(mime, "audio/"):
		return "audio"
	}
	return "document"
}

// ---------------------------------------------------------------- markRead

func (b *bridge) handleMarkRead(ctx context.Context, c call) {
	var params struct {
		ChatID string `json:"chatId"`
		UpTo   int64  `json:"upTo"`
	}
	if err := json.Unmarshal(c.Params, &params); err != nil {
		fail(c.ID, "bad_request", "%v", err)
		return
	}

	client := b.getClient()
	if client == nil || !client.IsLoggedIn() {
		// The host has already cleared the badge locally; a receipt we cannot
		// post is not worth surfacing as an error.
		ok(c.ID, nil)
		return
	}

	chat, err := types.ParseJID(params.ChatID)
	if err != nil {
		fail(c.ID, "bad_request", "not a valid conversation id: %v", err)
		return
	}

	// WhatsApp wants the specific message ids, which the host does not send.
	// Marking the conversation read at a timestamp is the closest honest
	// equivalent, and is what the official clients do on chat open.
	if err := client.MarkRead(ctx, nil, time.UnixMilli(params.UpTo), chat, types.EmptyJID); err != nil {
		logf("debug", "read receipt not accepted: %v", err)
	}

	ok(c.ID, nil)
}

// ---------------------------------------------------------------- revoke

func (b *bridge) handleRevoke(ctx context.Context, c call) {
	var params struct {
		ChatID    string `json:"chatId"`
		MessageID string `json:"messageId"`
	}
	if err := json.Unmarshal(c.Params, &params); err != nil {
		fail(c.ID, "bad_request", "%v", err)
		return
	}

	client := b.getClient()
	if client == nil || !client.IsLoggedIn() {
		fail(c.ID, "not_logged_in", "not signed in to WhatsApp")
		return
	}

	chat, err := types.ParseJID(params.ChatID)
	if err != nil {
		fail(c.ID, "bad_request", "not a valid conversation id: %v", err)
		return
	}

	if _, err := client.SendMessage(ctx, chat, client.BuildRevoke(chat, types.EmptyJID, params.MessageID)); err != nil {
		fail(c.ID, "revoke_failed", "%v", err)
		return
	}

	emitEvent("deleted", map[string]any{"chatId": params.ChatID, "messageId": params.MessageID})
	ok(c.ID, nil)
}

// ---------------------------------------------------------------- helpers

func expandPath(path string) string {
	path = strings.TrimPrefix(path, "file://")
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[2:])
		}
	}
	return path
}

func sanitize(s string) string {
	out := make([]rune, 0, len(s))
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-':
			out = append(out, r)
		default:
			out = append(out, '_')
		}
	}
	if len(out) == 0 {
		return "attachment"
	}
	if len(out) > 96 {
		out = out[:96]
	}
	return string(out)
}

var mimeExtensions = map[string]string{
	"image/jpeg":      ".jpg",
	"image/png":       ".png",
	"image/gif":       ".gif",
	"image/webp":      ".webp",
	"video/mp4":       ".mp4",
	"video/webm":      ".webm",
	"audio/ogg":       ".ogg",
	"audio/mpeg":      ".mp3",
	"audio/mp4":       ".m4a",
	"application/pdf": ".pdf",
}

func extensionFor(mime string) string {
	mime = strings.ToLower(strings.TrimSpace(strings.SplitN(mime, ";", 2)[0]))
	if ext, found := mimeExtensions[mime]; found {
		return ext
	}
	return ".bin"
}

func mimeForExtension(ext string) string {
	ext = strings.ToLower(ext)
	for mime, e := range mimeExtensions {
		if e == ext {
			return mime
		}
	}
	return ""
}
