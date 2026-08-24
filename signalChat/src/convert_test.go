package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
	"testing"
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

func testBridge() *bridge {
	b := newBridge()
	b.account = "+15550000000"
	return b
}

func TestIncomingDirectMessage(t *testing.T) {
	b := testBridge()
	env := envelope{
		SourceUUID: "uuid-ada",
		SourceName: "Ada",
		Timestamp:  1700000000000,
	}
	dm := &dataMessage{Timestamp: 1700000000000, Message: "hello"}

	msg := b.convert(env, dm, false)
	if msg == nil {
		t.Fatal("a plain text message must convert")
	}
	if msg.ChatID != "dm:uuid-ada" {
		t.Errorf("chat id = %q, want dm:uuid-ada", msg.ChatID)
	}
	if msg.FromMe {
		t.Error("an incoming message must not be fromMe")
	}
	if msg.Text != "hello" {
		t.Errorf("text = %q", msg.Text)
	}
}

// A message we sent from the phone belongs to the person we sent it *to*.
// Filing it under the sender would put our own replies in a conversation with
// ourselves.
func TestOwnMessageIsFiledUnderTheDestination(t *testing.T) {
	b := testBridge()
	env := envelope{
		SourceUUID: "uuid-self",
		Timestamp:  1700000000000,
		SyncMessage: &syncMessage{SentMessage: &sentMessage{
			DestinationUUID: "uuid-ada",
			dataMessage:     dataMessage{Timestamp: 1700000000000, Message: "hi back"},
		}},
	}
	inner := env.SyncMessage.SentMessage.dataMessage

	msg := b.convert(env, &inner, true)
	if msg == nil {
		t.Fatal("an echoed message must convert")
	}
	if msg.ChatID != "dm:uuid-ada" {
		t.Errorf("chat id = %q, want dm:uuid-ada", msg.ChatID)
	}
	if !msg.FromMe {
		t.Error("an echoed message must be fromMe")
	}
	if msg.Status != "sent" {
		t.Errorf("status = %q, want sent", msg.Status)
	}
}

// The id handleSend returns and the id the echo produces must match, or the
// conversation shows the same message twice.
func TestSentIDMatchesTheEchoedID(t *testing.T) {
	b := testBridge()
	const ts = 1700000000000

	fromSend := messageID(b.getAccount(), ts)

	env := envelope{
		SourceUUID: "uuid-self",
		SyncMessage: &syncMessage{SentMessage: &sentMessage{
			DestinationUUID: "uuid-ada",
			dataMessage:     dataMessage{Timestamp: ts, Message: "same message"},
		}},
	}
	inner := env.SyncMessage.SentMessage.dataMessage
	fromEcho := b.convert(env, &inner, true).ID

	if fromSend != fromEcho {
		t.Errorf("send returned %q but the echo produced %q; the upsert would not merge", fromSend, fromEcho)
	}
}

func TestGroupMessage(t *testing.T) {
	b := testBridge()
	env := envelope{SourceUUID: "uuid-ada", SourceName: "Ada"}
	dm := &dataMessage{
		Timestamp: 1700000000000,
		Message:   "in a group",
		GroupInfo: &groupInfo{GroupID: "abc==", GroupName: "Hikers"},
	}

	msg := b.convert(env, dm, false)
	if msg.ChatID != "grp:abc==" {
		t.Errorf("chat id = %q, want grp:abc==", msg.ChatID)
	}
	if msg.SenderName != "Ada" {
		t.Errorf("sender name = %q; group messages need one", msg.SenderName)
	}
}

func TestQuoteBecomesReplyTo(t *testing.T) {
	b := testBridge()
	env := envelope{SourceUUID: "uuid-ada"}
	dm := &dataMessage{
		Timestamp: 1700000001000,
		Message:   "replying",
		Quote:     &quote{ID: 1700000000000, AuthorUUID: "uuid-self", Text: "original"},
	}

	msg := b.convert(env, dm, false)
	if want := "uuid-self:1700000000000"; msg.ReplyTo != want {
		t.Errorf("replyTo = %q, want %q", msg.ReplyTo, want)
	}
}

// Signal allows several attachments on one message; the contract carries one.
// The extras must become their own messages rather than being dropped.
func TestExtraAttachmentsBecomeTheirOwnMessages(t *testing.T) {
	b := testBridge()
	env := envelope{SourceUUID: "uuid-ada"}
	dm := &dataMessage{
		Timestamp: 1700000000000,
		Message:   "three files",
		Attachments: []attachment{
			{ID: "a1", ContentType: "image/jpeg", Filename: "one.jpg"},
			{ID: "a2", ContentType: "image/png", Filename: "two.png"},
			{ID: "a3", ContentType: "application/pdf", Filename: "three.pdf"},
		},
	}

	var msg *messageObj
	frames := captureEvents(t, func() { msg = b.convert(env, dm, false) })

	if msg.MediaRef != "a1" || msg.Kind != "image" {
		t.Errorf("first attachment rides on the message, got ref=%q kind=%q", msg.MediaRef, msg.Kind)
	}
	if len(frames) != 2 {
		t.Fatalf("expected 2 sibling messages for the extra attachments, got %d", len(frames))
	}

	ids := map[string]bool{}
	for _, f := range frames {
		m, _ := f["message"].(map[string]any)
		id, _ := m["id"].(string)
		if ids[id] {
			t.Errorf("duplicate sibling id %q; the store would collapse them", id)
		}
		ids[id] = true
		if m["text"] != nil && m["text"] != "" {
			t.Error("a sibling must not repeat the caption")
		}
	}
	if ids[msg.ID] {
		t.Error("a sibling reused the original id")
	}
}

// A group update or expiry change carries no text and no attachment. Storing it
// would put a blank bubble in the conversation.
func TestEmptyProtocolMessageIsDropped(t *testing.T) {
	b := testBridge()
	if msg := b.convert(envelope{SourceUUID: "u"}, &dataMessage{Timestamp: 1}, false); msg != nil {
		t.Errorf("expected nil for an empty message, got %+v", msg)
	}
}

func TestReactionsAreNotMessages(t *testing.T) {
	b := testBridge()
	dm := &dataMessage{Timestamp: 1700000000000}
	dm.Reaction = &struct {
		Emoji               string `json:"emoji"`
		TargetAuthor        string `json:"targetAuthor"`
		TargetSentTimestamp int64  `json:"targetSentTimestamp"`
		IsRemove            bool   `json:"isRemove"`
	}{Emoji: "👍", TargetSentTimestamp: 1699999999000}

	frames := captureEvents(t, func() {
		b.onDataMessage(envelope{SourceUUID: "uuid-ada"}, dm, false)
	})
	for _, f := range frames {
		if f["event"] == "message" {
			t.Error("a reaction must not become a message")
		}
	}
}

func TestRemoteDeleteEmitsDeleted(t *testing.T) {
	b := testBridge()
	dm := &dataMessage{Timestamp: 1700000002000}
	dm.RemoteDelete = &struct {
		Timestamp int64 `json:"timestamp"`
	}{Timestamp: 1700000000000}

	frames := captureEvents(t, func() {
		b.onDataMessage(envelope{SourceUUID: "uuid-ada"}, dm, false)
	})
	if len(frames) != 1 || frames[0]["event"] != "deleted" {
		t.Fatalf("expected one deleted event, got %+v", frames)
	}
	if got := frames[0]["messageId"]; got != "uuid-ada:1700000000000" {
		t.Errorf("deleted the wrong message: %v", got)
	}
}

func TestReceiptsMapToTheStatusLadder(t *testing.T) {
	b := testBridge()

	for _, tc := range []struct {
		name    string
		receipt receiptMessage
		want    string
	}{
		{"delivery", receiptMessage{IsDelivery: true, Timestamps: []int64{1}}, "delivered"},
		{"read", receiptMessage{IsRead: true, Timestamps: []int64{1}}, "read"},
		{"viewed", receiptMessage{IsViewed: true, Timestamps: []int64{1}}, "read"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := tc.receipt
			frames := captureEvents(t, func() { b.onReceipt(&r) })
			if len(frames) != 1 {
				t.Fatalf("expected one status event, got %d", len(frames))
			}
			if frames[0]["status"] != tc.want {
				t.Errorf("status = %v, want %v", frames[0]["status"], tc.want)
			}
			// The receipt is about a message we sent, so it must be attributed
			// to this account or it will not match any stored row.
			if want := messageID(b.getAccount(), 1); frames[0]["messageId"] != want {
				t.Errorf("messageId = %v, want %v", frames[0]["messageId"], want)
			}
		})
	}

	t.Run("unknown receipt is ignored", func(t *testing.T) {
		r := receiptMessage{Timestamps: []int64{1}}
		if frames := captureEvents(t, func() { b.onReceipt(&r) }); len(frames) != 0 {
			t.Errorf("expected nothing, got %+v", frames)
		}
	})
}

func TestSplitMessageID(t *testing.T) {
	cases := []struct {
		in     string
		author string
		ts     int64
		ok     bool
	}{
		{"uuid-ada:1700000000000", "uuid-ada", 1700000000000, true},
		{"+15551234567:1700000000000", "+15551234567", 1700000000000, true},
		// A sibling id still refers to the original Signal message.
		{"uuid-ada:1700000000000#2", "uuid-ada", 1700000000000, true},
		// Author containing colons must split on the last one, not the first.
		{"a:b:c:1700000000000", "a:b:c", 1700000000000, true},
		{"nonsense", "", 0, false},
		{"uuid:notanumber", "", 0, false},
	}

	for _, c := range cases {
		author, ts, ok := splitMessageID(c.in)
		if ok != c.ok || author != c.author || ts != c.ts {
			t.Errorf("splitMessageID(%q) = (%q, %d, %v), want (%q, %d, %v)",
				c.in, author, ts, ok, c.author, c.ts, c.ok)
		}
	}
}

func TestRecipientOf(t *testing.T) {
	cases := []struct {
		in      string
		value   string
		isGroup bool
	}{
		{"dm:uuid-ada", "uuid-ada", false},
		{"grp:abc==", "abc==", true},
		// A bare id must be read as a recipient, never as a group.
		{"+15551234567", "+15551234567", false},
	}

	for _, c := range cases {
		value, isGroup := recipientOf(c.in)
		if value != c.value || isGroup != c.isGroup {
			t.Errorf("recipientOf(%q) = (%q, %v), want (%q, %v)", c.in, value, isGroup, c.value, c.isGroup)
		}
	}
}

func TestKindOf(t *testing.T) {
	cases := map[string]attachment{
		"image":    {ContentType: "image/jpeg"},
		"video":    {ContentType: "video/mp4"},
		"audio":    {ContentType: "audio/ogg"},
		"sticker":  {ContentType: "image/webp", IsSticker: true},
		"document": {ContentType: "application/pdf"},
	}
	for want, a := range cases {
		if got := kindOf(a); got != want {
			t.Errorf("kindOf(%+v) = %q, want %q", a, got, want)
		}
	}

	// A voice note is audio even though Signal sends it as a generic type.
	if got := kindOf(attachment{ContentType: "application/octet-stream", IsVoiceNote: true}); got != "audio" {
		t.Errorf("voice note kind = %q, want audio", got)
	}
}

func TestContactDisplayNamePrefersTheNameYouChose(t *testing.T) {
	c := contact{
		Number:      "+15551234567",
		Nickname:    "Ada",
		Name:        "Ada Lovelace",
		ProfileName: "A.L.",
	}
	if got := contactDisplayName(c); got != "Ada" {
		t.Errorf("display name = %q, want the nickname Ada", got)
	}

	// Falling all the way through to the number is better than showing nothing.
	if got := contactDisplayName(contact{Number: "+15551234567"}); got != "+15551234567" {
		t.Errorf("display name = %q, want the number", got)
	}
}

// The UUID is preferred because a phone number can change while the account
// stays the same; keying on the number would split the conversation in two.
func TestContactIDPrefersUUID(t *testing.T) {
	if got := contactID(contact{Number: "+1555", UUID: "uuid-ada"}); got != "uuid-ada" {
		t.Errorf("contact id = %q, want uuid-ada", got)
	}
	if got := contactID(contact{Number: "+1555"}); got != "+1555" {
		t.Errorf("contact id = %q, want the number as fallback", got)
	}
}

func TestHandlesAreDeduplicatedAndOrdered(t *testing.T) {
	got := handlesFor(contact{Number: "+1555", Username: "ada.42", UUID: "uuid-ada"})
	want := []string{"+1555", "ada.42", "uuid-ada"}
	if len(got) != len(want) {
		t.Fatalf("handles = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("handles = %v, want %v", got, want)
		}
	}

	// An empty username must not become an empty handle, which would match
	// everything.
	for _, h := range handlesFor(contact{Number: "+1555"}) {
		if h == "" {
			t.Error("an empty handle was emitted")
		}
	}
}
