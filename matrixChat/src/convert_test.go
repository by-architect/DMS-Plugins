package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto/attachment"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// captureEvents redirects the protocol writer so a test can read what the bridge
// would have emitted.
func captureEvents(t *testing.T, fn func()) []map[string]any {
	t.Helper()

	var buf bytes.Buffer
	out.mu.Lock()
	previous := out.w
	out.w = bufio.NewWriter(&buf)
	out.mu.Unlock()

	fn()

	out.mu.Lock()
	out.w.Flush()
	out.w = previous
	out.mu.Unlock()

	var frames []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var f map[string]any
		if err := json.Unmarshal([]byte(line), &f); err != nil {
			t.Fatalf("emitted a line that is not JSON: %v\n%s", err, line)
		}
		frames = append(frames, f)
	}
	return frames
}

const (
	testRoom = id.RoomID("!room:example.org")
	testSelf = id.UserID("@me:example.org")
	testAda  = id.UserID("@ada:example.org")
)

func testBridge() *bridge {
	b := newBridge()
	b.sess = &session{UserID: string(testSelf)}
	b.firstSyncDone = true
	return b
}

func msgEvent(sender id.UserID, content *event.MessageEventContent) *event.Event {
	evt := &event.Event{
		ID:        id.EventID("$evt1"),
		RoomID:    testRoom,
		Sender:    sender,
		Timestamp: 1700000000000,
		Type:      event.EventMessage,
	}
	evt.Content.Parsed = content
	return evt
}

func TestIncomingTextMessage(t *testing.T) {
	b := testBridge()
	b.room(testRoom).Members[testAda] = "Ada"

	evt := msgEvent(testAda, &event.MessageEventContent{MsgType: event.MsgText, Body: "hello"})
	msg := b.convert(evt, evt.Content.Parsed.(*event.MessageEventContent), evt.ID)

	if msg == nil {
		t.Fatal("a plain text message must convert")
	}
	if msg.ChatID != string(testRoom) {
		t.Errorf("chat id = %q", msg.ChatID)
	}
	if msg.FromMe {
		t.Error("an incoming message must not be fromMe")
	}
	if msg.SenderName != "Ada" {
		t.Errorf("sender name = %q, want the per-room display name Ada", msg.SenderName)
	}
}

func TestOwnMessageIsMarkedSent(t *testing.T) {
	b := testBridge()
	evt := msgEvent(testSelf, &event.MessageEventContent{MsgType: event.MsgText, Body: "mine"})
	msg := b.convert(evt, evt.Content.Parsed.(*event.MessageEventContent), evt.ID)

	if !msg.FromMe {
		t.Error("a message from this account must be fromMe")
	}
	if msg.Status != "sent" {
		t.Errorf("status = %q, want sent", msg.Status)
	}
}

// An edit must land on the original id, or the host's upsert appends a
// near-duplicate instead of replacing the text in place.
func TestEditReplacesTheOriginal(t *testing.T) {
	b := testBridge()

	content := &event.MessageEventContent{
		MsgType: event.MsgText,
		Body:    "* corrected",
		RelatesTo: &event.RelatesTo{
			Type:    event.RelReplace,
			EventID: id.EventID("$original"),
		},
		NewContent: &event.MessageEventContent{MsgType: event.MsgText, Body: "corrected"},
	}
	evt := msgEvent(testAda, content)
	evt.ID = id.EventID("$edit")

	frames := captureEvents(t, func() { b.onMessage(context.Background(), evt) })

	// As a batch, never as a message of its own: only the single event can
	// notify, and a correction is not news.
	var got map[string]any
	for _, f := range frames {
		switch f["event"] {
		case "message":
			t.Errorf("an edit went out as a new message: %+v", f)
		case "messages":
			list, _ := f["messages"].([]any)
			if len(list) == 1 {
				got, _ = list[0].(map[string]any)
			}
		}
	}
	if got == nil {
		t.Fatal("the edit produced no message")
	}
	if got["id"] != "$original" {
		t.Errorf("edit was stored as %v, want $original", got["id"])
	}
	if got["text"] != "corrected" {
		t.Errorf("text = %v, want the new content", got["text"])
	}
}

// Matrix prepends the quoted original to a reply's body for old clients. Left
// in, every reply would show the original quoted inside it.
func TestReplyFallbackIsStripped(t *testing.T) {
	b := testBridge()

	content := &event.MessageEventContent{
		MsgType:   event.MsgText,
		Body:      "> <@ada:example.org> original question\n> second line\n\nmy answer",
		RelatesTo: (&event.RelatesTo{}).SetReplyTo(id.EventID("$original")),
	}
	evt := msgEvent(testAda, content)
	msg := b.convert(evt, content, evt.ID)

	if msg.Text != "my answer" {
		t.Errorf("text = %q, want just the reply", msg.Text)
	}
	if msg.ReplyTo != "$original" {
		t.Errorf("replyTo = %q", msg.ReplyTo)
	}
}

func TestStripReplyFallbackHTML(t *testing.T) {
	in := `<mx-reply><blockquote>quoted</blockquote></mx-reply>the answer`
	if got := stripReplyFallbackHTML(in); got != "the answer" {
		t.Errorf("got %q", got)
	}
	// Untouched when there is no fallback to remove.
	if got := stripReplyFallbackHTML("<b>plain</b>"); got != "<b>plain</b>" {
		t.Errorf("got %q", got)
	}
}

func TestMediaFields(t *testing.T) {
	b := testBridge()

	content := &event.MessageEventContent{
		MsgType: event.MsgImage,
		Body:    "photo.jpg",
		URL:     id.ContentURIString("mxc://example.org/abc123"),
		Info: &event.FileInfo{
			MimeType: "image/jpeg",
			Size:     4096,
			Width:    800,
			Height:   600,
			Duration: 5000,
		},
	}
	evt := msgEvent(testAda, content)
	msg := b.convert(evt, content, evt.ID)

	if msg.Kind != "image" {
		t.Errorf("kind = %q", msg.Kind)
	}
	if msg.MediaRef != "mxc://example.org/abc123" {
		t.Errorf("mediaRef = %q", msg.MediaRef)
	}
	if msg.MediaW != 800 || msg.MediaH != 600 {
		t.Errorf("dimensions = %dx%d", msg.MediaW, msg.MediaH)
	}
	// Matrix reports milliseconds; the contract wants seconds.
	if msg.Duration != 5 {
		t.Errorf("duration = %d, want 5 seconds", msg.Duration)
	}
	// The body of a media message is the filename; repeating it as text would
	// show the name twice.
	if msg.Text != "" {
		t.Errorf("text = %q, want empty when it only repeats the filename", msg.Text)
	}
}

// An encrypted attachment carries its URL inside the file block, not at the top
// level, and the key that opens it beside the URL. Missing the first made every
// attachment in an encrypted room undownloadable; missing the second made it
// download as ciphertext.
func TestEncryptedAttachmentURL(t *testing.T) {
	b := testBridge()

	file := &event.EncryptedFileInfo{
		EncryptedFile: *attachment.NewEncryptedFile(),
		URL:           id.ContentURIString("mxc://example.org/enc456"),
	}
	content := &event.MessageEventContent{
		MsgType: event.MsgFile,
		Body:    "secret.pdf",
		File:    file,
	}
	evt := msgEvent(testAda, content)
	msg := b.convert(evt, content, evt.ID)

	uri, key, err := parseMediaRef(msg.MediaRef)
	if err != nil {
		t.Fatalf("the ref does not parse back: %v", err)
	}
	if uri.String() != "mxc://example.org/enc456" {
		t.Errorf("uri = %q, want the URL from the encrypted file block", uri.String())
	}
	if key == nil || key.Key.Key != file.Key.Key || key.InitVector != file.InitVector {
		t.Errorf("the key did not travel with the ref: %+v", key)
	}

	// An unencrypted attachment's ref is still the plain URI.
	plain := &event.MessageEventContent{MsgType: event.MsgFile, Body: "a.pdf", URL: "mxc://example.org/plain"}
	if ref := b.convert(evt, plain, evt.ID).MediaRef; ref != "mxc://example.org/plain" {
		t.Errorf("plain ref = %q", ref)
	}
}

func TestEmptyMessageIsDropped(t *testing.T) {
	b := testBridge()
	content := &event.MessageEventContent{MsgType: event.MsgText}
	evt := msgEvent(testAda, content)

	if msg := b.convert(evt, content, evt.ID); msg != nil {
		t.Errorf("expected nil for an empty message, got %+v", msg)
	}
}

func TestRedactionEmitsDeleted(t *testing.T) {
	b := testBridge()
	evt := &event.Event{RoomID: testRoom, Redacts: id.EventID("$gone"), Type: event.EventRedaction}

	frames := captureEvents(t, func() { b.onRedaction(context.Background(), evt) })
	if len(frames) != 1 || frames[0]["event"] != "deleted" {
		t.Fatalf("expected one deleted event, got %+v", frames)
	}
	if frames[0]["messageId"] != "$gone" {
		t.Errorf("deleted the wrong message: %v", frames[0]["messageId"])
	}
}

// Our own read receipt says nothing about whether anyone else read it, and
// would mark our own messages read the moment we send them.
// Our own receipt is not somebody else having read our message. It says where
// we have read up to, which is tested in read_test.go.
func TestOwnReceiptIsNotSomeoneElsesRead(t *testing.T) {
	b := testBridge()

	content := event.ReceiptEventContent{
		id.EventID("$evt"): {
			event.ReceiptTypeRead: {testSelf: event.ReadReceipt{}},
		},
	}
	evt := &event.Event{RoomID: testRoom, Type: event.EphemeralEventReceipt}
	evt.Content.Parsed = &content

	if frames := captureEvents(t, func() { b.onReceipt(context.Background(), evt) }); len(frames) != 0 {
		t.Errorf("our own receipt produced %+v", frames)
	}

	// Someone else's receipt is a real read.
	content2 := event.ReceiptEventContent{
		id.EventID("$evt"): {
			event.ReceiptTypeRead: {testAda: event.ReadReceipt{}},
		},
	}
	evt2 := &event.Event{RoomID: testRoom, Type: event.EphemeralEventReceipt}
	evt2.Content.Parsed = &content2

	frames := captureEvents(t, func() { b.onReceipt(context.Background(), evt2) })
	if len(frames) != 1 || frames[0]["status"] != "read" {
		t.Fatalf("expected one read status, got %+v", frames)
	}
}

// ---------------------------------------------------------------- naming

func TestDisplayNamePrecedence(t *testing.T) {
	b := testBridge()
	info := b.room(testRoom)
	info.Members[testAda] = "Ada"
	info.Alias = "#general:example.org"

	// Alias beats members.
	if got := b.displayName(testRoom); got != "#general:example.org" {
		t.Errorf("with an alias: %q", got)
	}

	// An explicit name beats everything.
	info.Name = "The Room"
	if got := b.displayName(testRoom); got != "The Room" {
		t.Errorf("with a name: %q", got)
	}
}

// A direct message usually has neither a name nor an alias, and must be named
// after whoever else is in it rather than shown as a raw room id.
func TestDisplayNameFallsBackToMembers(t *testing.T) {
	b := testBridge()
	info := b.room(testRoom)
	info.Members[testSelf] = "Me"
	info.Members[testAda] = "Ada"

	if got := b.displayName(testRoom); got != "Ada" {
		t.Errorf("one other member: %q, want Ada", got)
	}

	info.Members[id.UserID("@bob:example.org")] = "Bob"
	if got := b.displayName(testRoom); got != "Ada and Bob" {
		t.Errorf("two others: %q", got)
	}

	info.Members[id.UserID("@cy:example.org")] = "Cy"
	if got := b.displayName(testRoom); got != "Ada and 2 others" {
		t.Errorf("three others: %q", got)
	}
}

func TestDisplayNameOfUnknownRoom(t *testing.T) {
	b := testBridge()
	if got := b.displayName(id.RoomID("!never-seen:example.org")); got != "!never-seen:example.org" {
		t.Errorf("got %q, want the room id as a last resort", got)
	}
}

// In a room of four hundred people every member id would become a handle, and
// searching any one of them would surface the room rather than the person.
func TestHandlesOnlyIncludeMembersForDirectChats(t *testing.T) {
	b := testBridge()
	info := b.room(testRoom)
	info.Alias = "#general:example.org"
	info.Members[testSelf] = "Me"
	info.Members[testAda] = "Ada"

	handles := b.handlesFor(testRoom)
	if len(handles) != 1 || handles[0] != "#general:example.org" {
		t.Errorf("group handles = %v, want only the alias", handles)
	}

	info.IsDirect = true
	handles = b.handlesFor(testRoom)
	joined := strings.Join(handles, ",")
	if !strings.Contains(joined, string(testAda)) {
		t.Errorf("direct handles = %v, want the other person's user id", handles)
	}
	if strings.Contains(joined, string(testSelf)) {
		t.Errorf("direct handles = %v, must not include ourselves", handles)
	}
}

func TestTags(t *testing.T) {
	b := testBridge()
	info := b.room(testRoom)
	info.IsSpace = true
	info.Encrypted = true
	info.Tags = []string{"m.favourite"}

	got := strings.Join(b.tagsFor(testRoom), ",")
	for _, want := range []string{"space", "encrypted", "favourite"} {
		if !strings.Contains(got, want) {
			t.Errorf("tags = %q, missing %q", got, want)
		}
	}
}

// A member who leaves must stop naming the room.
func TestLeavingRemovesAMember(t *testing.T) {
	b := testBridge()

	join := &event.Event{RoomID: testRoom, Type: event.StateMember}
	stateKey := string(testAda)
	join.StateKey = &stateKey
	join.Content.Parsed = &event.MemberEventContent{Membership: event.MembershipJoin, Displayname: "Ada"}
	b.onMember(context.Background(), join)

	if b.senderName(testRoom, testAda) != "Ada" {
		t.Fatal("join did not record the member")
	}

	leave := &event.Event{RoomID: testRoom, Type: event.StateMember}
	leave.StateKey = &stateKey
	leave.Content.Parsed = &event.MemberEventContent{Membership: event.MembershipLeave}
	b.onMember(context.Background(), leave)

	b.mu.RLock()
	_, still := b.rooms[testRoom].Members[testAda]
	b.mu.RUnlock()
	if still {
		t.Error("a member who left is still in the room")
	}
}

func TestMsgTypeAndMime(t *testing.T) {
	cases := map[string]event.MessageType{
		"a.png":  event.MsgImage,
		"a.mp4":  event.MsgVideo,
		"a.ogg":  event.MsgAudio,
		"a.pdf":  event.MsgFile,
		"a.what": event.MsgFile,
	}
	for name, want := range cases {
		if got := msgTypeFor(mimeOf(name)); got != want {
			t.Errorf("%s -> %v, want %v", name, got, want)
		}
	}
}

// Publishing reads a room's record from goroutines of its own while the sync
// loop writes it. Naming a room ranges over its member map, and a map written
// mid-range is not a race Go forgives: the runtime ends the process. Run with
// -race to see every unguarded access; without it, this still trips the
// runtime's own check on code that reads the members unlocked.
func TestRoomRecordsSurviveConcurrentSyncAndPublish(t *testing.T) {
	b := testBridge()
	b.room(testRoom).Members[testAda] = "Ada"

	member := func(user id.UserID, membership event.Membership) *event.Event {
		evt := &event.Event{RoomID: testRoom, Type: event.StateMember}
		key := string(user)
		evt.StateKey = &key
		evt.Content.Parsed = &event.MemberEventContent{Membership: membership, Displayname: "Someone"}
		return evt
	}
	named := &event.Event{RoomID: testRoom, Type: event.StateRoomName}
	named.Content.Parsed = &event.RoomNameEventContent{Name: ""}

	captureEvents(t, func() {
		done := make(chan struct{})
		go func() {
			defer close(done)
			ctx := context.Background()
			for i := 0; i < 2000; i++ {
				user := id.UserID("@u" + strconv.Itoa(i%40) + ":example.org")
				b.onMember(ctx, member(user, event.MembershipJoin))
				b.onRoomName(ctx, named)
				b.onMember(ctx, member(user, event.MembershipLeave))
			}
		}()

		for {
			select {
			case <-done:
				return
			default:
			}
			_ = b.displayName(testRoom)
			_ = b.chatFor(testRoom)
			_ = b.inviteLine(testRoom)
		}
	})
}

// ---------------------------------------------------------------- live or history

// An initial sync's timeline is history: held back, and sent as one batch the
// host stores without notifying. Sent message by message, a fresh sign-in
// notified for whatever the last half hour held.
func TestInitialSyncHistoryIsBatched(t *testing.T) {
	b := testBridge()
	initial := context.WithValue(context.Background(), mautrix.SyncTokenContextKey, "")

	image := &event.MessageEventContent{MsgType: event.MsgImage, Body: "a.png", URL: "mxc://example.org/img"}
	evt := msgEvent(testAda, image)

	frames := captureEvents(t, func() { b.onMessage(initial, evt) })
	if len(frames) != 0 {
		t.Fatalf("history went out before the response was read through: %+v", frames)
	}
	if b.downloads != nil {
		t.Error("history queued an attachment download")
	}

	frames = captureEvents(t, b.flushHistory)
	if len(frames) != 1 || frames[0]["event"] != "messages" {
		t.Fatalf("history was not sent as one batch: %+v", frames)
	}
	if list, _ := frames[0]["messages"].([]any); len(list) != 1 {
		t.Errorf("batch held %d messages, want 1", len(list))
	}
}

// A message arriving on a sync that resumed from a position is news, and goes
// out on its own -- the one event the host may notify for.
func TestLiveMessageGoesOutAlone(t *testing.T) {
	b := testBridge()
	live := context.WithValue(context.Background(), mautrix.SyncTokenContextKey, "s123")

	evt := msgEvent(testAda, &event.MessageEventContent{MsgType: event.MsgText, Body: "hello"})
	frames := captureEvents(t, func() { b.onMessage(live, evt) })

	if len(frames) == 0 || frames[0]["event"] != "message" {
		t.Fatalf("a live message did not go out as a message: %+v", frames)
	}
}

// ---------------------------------------------------------------- attachments

func encryptedAttachment(t *testing.T, plaintext []byte) (*event.EncryptedFileInfo, []byte) {
	t.Helper()
	file := &event.EncryptedFileInfo{
		EncryptedFile: *attachment.NewEncryptedFile(),
		URL:           "mxc://example.org/enc",
	}
	ciphertext := append([]byte(nil), plaintext...)
	file.EncryptInPlace(ciphertext)
	return file, ciphertext
}

// What a ref carries for an encrypted room is enough to open the file: written
// as it arrived, every attachment in such a room was saved as ciphertext.
func TestEncryptedAttachmentIsDecryptedOnDownload(t *testing.T) {
	dir := t.TempDir()
	plaintext := []byte("the picture itself")
	file, ciphertext := encryptedAttachment(t, plaintext)

	ref, _ := json.Marshal(file)
	_, key, err := parseMediaRef(string(ref))
	if err != nil {
		t.Fatalf("parse ref: %v", err)
	}

	path, err := saveAttachment(dir, "enc", bytes.NewReader(ciphertext), key, 0)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if got, _ := os.ReadFile(path); !bytes.Equal(got, plaintext) {
		t.Errorf("saved %q, want the decrypted file", got)
	}
}

// A file whose hash does not match is not the file that was sent, and nothing
// is left behind for the host to point at.
func TestTamperedAttachmentIsNotSaved(t *testing.T) {
	dir := t.TempDir()
	file, ciphertext := encryptedAttachment(t, []byte("the picture itself"))
	ciphertext[0] ^= 0xff

	if _, err := saveAttachment(dir, "enc", bytes.NewReader(ciphertext), file, 0); err == nil {
		t.Fatal("a file that failed its hash was saved")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("left behind: %v", entries)
	}
}

// The auto-download limit holds whatever size the sender claimed, or failed to.
func TestAttachmentOverTheLimitIsNotSaved(t *testing.T) {
	dir := t.TempDir()
	_, err := saveAttachment(dir, "big", bytes.NewReader(make([]byte, 2048)), nil, 1024)
	if !errors.Is(err, errTooLarge) {
		t.Fatalf("err = %v, want errTooLarge", err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("left behind: %v", entries)
	}

	path, err := saveAttachment(dir, "small", bytes.NewReader(make([]byte, 512)), nil, 1024)
	if err != nil {
		t.Fatalf("a file under the limit was refused: %v", err)
	}
	if info, _ := os.Stat(path); info == nil || info.Size() != 512 {
		t.Errorf("saved %v, want 512 bytes", info)
	}
}

// ---------------------------------------------------------------- sending

// fakeSender records what sending would have put on the wire.
type fakeSender struct {
	uploaded   []byte
	uploadMime string
	sent       []*event.MessageEventContent
}

func (f *fakeSender) SendMessageEvent(_ context.Context, _ id.RoomID, _ event.Type, content interface{}, _ ...mautrix.ReqSendEvent) (*mautrix.RespSendEvent, error) {
	f.sent = append(f.sent, content.(*event.MessageEventContent))
	return &mautrix.RespSendEvent{EventID: id.EventID("$sent" + strconv.Itoa(len(f.sent)))}, nil
}

func (f *fakeSender) UploadBytes(_ context.Context, data []byte, contentType string) (*mautrix.RespMediaUpload, error) {
	f.uploaded = append([]byte(nil), data...)
	f.uploadMime = contentType
	return &mautrix.RespMediaUpload{ContentURI: id.ContentURI{Homeserver: "example.org", FileID: "up1"}}, nil
}

// A caption travels in the file's own event, as Matrix 1.10 has it. Sent as a
// second event it came back as a second message, and the attachment showed
// twice.
func TestCaptionAndReplyRideOnTheFile(t *testing.T) {
	b := testBridge()
	path := filepath.Join(t.TempDir(), "photo.png")
	if err := os.WriteFile(path, []byte("png bytes"), 0o600); err != nil {
		t.Fatal(err)
	}

	sender := &fakeSender{}
	if _, err := b.sendFile(context.Background(), sender, testRoom, path, "look at this", "$question", false); err != nil {
		t.Fatalf("send: %v", err)
	}
	if len(sender.sent) != 1 {
		t.Fatalf("sent %d events, want the file and its caption as one", len(sender.sent))
	}
	content := sender.sent[0]
	if content.Body != "look at this" || content.FileName != "photo.png" {
		t.Errorf("body = %q, filename = %q", content.Body, content.FileName)
	}
	if content.RelatesTo.GetReplyTo() != "$question" {
		t.Errorf("reply = %q, want it on the file event", content.RelatesTo.GetReplyTo())
	}
	if content.URL != "mxc://example.org/up1" || content.File != nil {
		t.Errorf("an unencrypted room got url=%q file=%v", content.URL, content.File)
	}
}

// Into an encrypted room the file is encrypted before it is uploaded, and the
// key goes in the event. Uploaded as it was, the homeserver kept a readable
// copy of it.
func TestAttachmentIsEncryptedForAnEncryptedRoom(t *testing.T) {
	b := testBridge()
	plaintext := []byte("png bytes")
	path := filepath.Join(t.TempDir(), "photo.png")
	if err := os.WriteFile(path, plaintext, 0o600); err != nil {
		t.Fatal(err)
	}

	sender := &fakeSender{}
	if _, err := b.sendFile(context.Background(), sender, testRoom, path, "", "", true); err != nil {
		t.Fatalf("send: %v", err)
	}
	content := sender.sent[0]
	if content.File == nil || content.URL != "" {
		t.Fatalf("file = %v, url = %q: the attachment went out unencrypted", content.File, content.URL)
	}
	if bytes.Equal(sender.uploaded, plaintext) || sender.uploadMime != "application/octet-stream" {
		t.Errorf("uploaded %q as %s, want ciphertext", sender.uploaded, sender.uploadMime)
	}
	if content.File.URL != "mxc://example.org/up1" {
		t.Errorf("file url = %q", content.File.URL)
	}

	// Opened the way a recipient opens it: from the event as it arrives, not
	// from the sender's own copy, which mautrix caches without the hash.
	wire, _ := json.Marshal(content.File)
	var received event.EncryptedFileInfo
	if err := json.Unmarshal(wire, &received); err != nil {
		t.Fatal(err)
	}
	opened := append([]byte(nil), sender.uploaded...)
	if err := received.DecryptInPlace(opened); err != nil || !bytes.Equal(opened, plaintext) {
		t.Errorf("the event's key does not open the upload: %v", err)
	}
}

// With encryption not working, a message for an encrypted room is refused
// rather than sent: mautrix encrypts only when it holds a crypto helper, and
// without one it sent in plain text.
func TestNoPlainTextIntoAnEncryptedRoom(t *testing.T) {
	b := testBridge()
	client, err := mautrix.NewClient("https://example.invalid", testSelf, "token")
	if err != nil {
		t.Fatal(err)
	}
	b.client = client
	b.room(testRoom).Encrypted = true

	params, _ := json.Marshal(map[string]any{"chatId": string(testRoom), "text": "secret"})
	frames := captureEvents(t, func() {
		b.handleSend(context.Background(), call{ID: 7, Method: "send", Params: params})
	})

	if len(frames) != 1 || frames[0]["ok"] != false {
		t.Fatalf("the send was not refused: %+v", frames)
	}
	if errInfo, _ := frames[0]["error"].(map[string]any); errInfo["code"] != "no_encryption" {
		t.Errorf("error = %v, want no_encryption", frames[0]["error"])
	}
}
