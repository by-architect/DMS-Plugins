package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

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

	var got map[string]any
	for _, f := range frames {
		if f["event"] == "message" {
			got, _ = f["message"].(map[string]any)
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
// level. Missing this makes every attachment in an encrypted room undownloadable.
func TestEncryptedAttachmentURL(t *testing.T) {
	b := testBridge()

	content := &event.MessageEventContent{
		MsgType: event.MsgFile,
		Body:    "secret.pdf",
		File: &event.EncryptedFileInfo{
			URL: id.ContentURIString("mxc://example.org/enc456"),
		},
	}
	evt := msgEvent(testAda, content)
	msg := b.convert(evt, content, evt.ID)

	if msg.MediaRef != "mxc://example.org/enc456" {
		t.Errorf("mediaRef = %q, want the URL from the encrypted file block", msg.MediaRef)
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
