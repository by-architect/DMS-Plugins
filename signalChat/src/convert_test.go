package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
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
	// Off, so converting an attachment starts no background download. With
	// nothing connected that download fails and logs -- from a goroutine that
	// outlives its test, into whichever test is capturing output next, which
	// made the suite fail depending on timing.
	b.settings["autoDownloadMedia"] = false
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
	// One batch: the extras are parts of a message that is announced on its
	// own, so none of them may go out as a live message event.
	if len(frames) != 1 || frames[0]["event"] != "messages" {
		t.Fatalf("expected the extra attachments as one messages batch, got %+v", frames)
	}
	siblings, _ := frames[0]["messages"].([]any)
	if len(siblings) != 2 {
		t.Fatalf("expected 2 sibling messages for the extra attachments, got %d", len(siblings))
	}

	ids := map[string]bool{}
	for _, s := range siblings {
		m, _ := s.(map[string]any)
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

// ---------------------------------------------------------------- read state

// A message read on the phone has to move the conversation's read position:
// a status on the message is not what the host counts. The read sync names the
// author by UUID as well as by number, and the UUID is what messages are keyed
// on -- matching on the number alone found nothing.
func TestReadOnThePhoneMovesTheReadPosition(t *testing.T) {
	b := testBridge()
	captureEvents(t, func() {
		b.onDataMessage(envelope{SourceUUID: "uuid-ada", SourceNumber: "+1555"}, &dataMessage{Timestamp: 1000, Message: "first"}, false)
		b.onDataMessage(envelope{SourceUUID: "uuid-ada", SourceNumber: "+1555"}, &dataMessage{Timestamp: 2000, Message: "second"}, false)
		b.onDataMessage(envelope{SourceUUID: "uuid-ada"}, &dataMessage{
			Timestamp: 1500, Message: "in a group", GroupInfo: &groupInfo{GroupID: "abc=="},
		}, false)
	})

	env := envelope{SyncMessage: &syncMessage{}}
	if err := json.Unmarshal([]byte(`{"readMessages":[
		{"sender":"+1555","senderNumber":"+1555","senderUuid":"uuid-ada","timestamp":1000},
		{"sender":"+1555","senderNumber":"+1555","senderUuid":"uuid-ada","timestamp":1500},
		{"sender":"+1999","senderNumber":"+1999","timestamp":42}
	]}`), env.SyncMessage); err != nil {
		t.Fatal(err)
	}
	frames := captureEvents(t, func() { b.onSync(env) })

	readUpTo := map[string]float64{}
	var statuses []string
	for _, f := range frames {
		switch f["event"] {
		case "chat":
			c := f["chat"].(map[string]any)
			readUpTo[c["id"].(string)] = c["readUpTo"].(float64)
		case "status":
			statuses = append(statuses, f["messageId"].(string))
		}
	}

	if readUpTo["dm:uuid-ada"] != 1000 {
		t.Errorf("direct conversation read up to %v, want 1000", readUpTo["dm:uuid-ada"])
	}
	if readUpTo["grp:abc=="] != 1500 {
		t.Errorf("group read up to %v, want 1500: a read sync must find the conversation the message was filed under", readUpTo["grp:abc=="])
	}
	if len(readUpTo) != 2 {
		t.Errorf("a message this bridge never saw must not move any conversation: %v", readUpTo)
	}
	if len(statuses) == 0 || statuses[0] != "uuid-ada:1000" {
		t.Errorf("status ids %v; want them keyed on the UUID, like the messages", statuses)
	}

	// Read on the phone means no receipt is owed from here. What arrived after
	// it is still waiting.
	if refs := b.unread["dm:uuid-ada"]; len(refs) != 1 || refs[0].ts != 2000 {
		t.Errorf("still waiting in the direct conversation: %+v, want only the message at 2000", refs)
	}
	if refs := b.unread["grp:abc=="]; len(refs) != 0 {
		t.Errorf("still waiting in the group: %+v, want nothing", refs)
	}
}

// An edit is the same message again. Sent as a live message it would count as
// news a second time.
func TestEditIsNotANewMessage(t *testing.T) {
	b := testBridge()
	env := envelope{SourceUUID: "uuid-ada", EditMessage: &editMessage{
		TargetSentTimestamp: 1000,
		DataMessage:         &dataMessage{Timestamp: 1100, Message: "fixed the typo"},
	}}

	frames := captureEvents(t, func() { b.handleEnvelope(env) })

	var batch []any
	for _, f := range frames {
		if f["event"] == "message" {
			t.Fatalf("an edit went out as a live message: %+v", f)
		}
		if f["event"] == "messages" {
			batch, _ = f["messages"].([]any)
		}
	}
	if len(batch) != 1 {
		t.Fatalf("expected the edit as a batch of one, got %+v", frames)
	}
	if m := batch[0].(map[string]any); m["id"] != "uuid-ada:1000" || m["text"] != "fixed the typo" {
		t.Errorf("the edit must replace the original in place, got %+v", m)
	}
	if len(b.unread) != 0 {
		t.Errorf("an edit must not wait for a read receipt of its own: %+v", b.unread)
	}
}

// The settings decide what reaches the host as a message arrives. Above the
// size limit, or with the setting off, only the ref goes -- and opening it
// finds the file signal-cli already has.
func TestAttachmentsReachTheHostOnlyWhenWanted(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("SIGNAL_CLI_DATA_DIR", dir)
	if err := os.MkdirAll(filepath.Join(dir, "attachments"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"small.jpg", "big.mp4"} {
		if err := os.WriteFile(filepath.Join(dir, "attachments", name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	b := testBridge()
	b.settings["autoDownloadMedia"] = true
	b.settings["autoDownloadMaxMB"] = float64(1) // JSON numbers arrive as float64

	var small, big, off messageObj
	b.applyAttachment(&small, attachment{ID: "small.jpg", ContentType: "image/jpeg", Size: 1024})
	b.applyAttachment(&big, attachment{ID: "big.mp4", ContentType: "video/mp4", Size: 5 << 20})
	b.settings["autoDownloadMedia"] = false
	b.applyAttachment(&off, attachment{ID: "small.jpg", ContentType: "image/jpeg", Size: 1024})

	if small.MediaPath == "" {
		t.Error("an attachment under the limit should reach the host as it arrives")
	}
	if big.MediaPath != "" || off.MediaPath != "" {
		t.Errorf("over the limit or with the setting off, only the ref should go: big=%q off=%q", big.MediaPath, off.MediaPath)
	}
	if big.MediaRef != "big.mp4" {
		t.Errorf("ref = %q; without it the attachment could never be opened", big.MediaRef)
	}

	frames := captureEvents(t, func() {
		b.handleFetchMedia(context.Background(), call{ID: 7, Method: "fetchMedia", Params: json.RawMessage(`{"chatId":"dm:x","messageId":"m","ref":"big.mp4"}`)})
	})
	if len(frames) != 1 || frames[0]["ok"] != true {
		t.Fatalf("opening a held-back attachment failed: %+v", frames)
	}
	if path := frames[0]["result"].(map[string]any)["path"]; path != filepath.Join(dir, "attachments", "big.mp4") {
		t.Errorf("fetched %v, want signal-cli's own copy", path)
	}
}

// ---------------------------------------------------------------- signal-cli

// TestHelperSignalCLI is not a test. It stands in for signal-cli in the tests
// that need a real child process: they run this test binary again, with
// SIGNAL_CLI_HELPER saying how the stand-in should behave.
func TestHelperSignalCLI(t *testing.T) {
	switch os.Getenv("SIGNAL_CLI_HELPER") {
	case "":
		return

	case "die":
		// Explains itself on stderr and exits on its own, as signal-cli does
		// when it fails -- with the explanation last, where it is easiest to
		// lose.
		for i := 0; i < 20; i++ {
			fmt.Fprintf(os.Stderr, "at frame %d\n", i)
		}
		fmt.Fprintln(os.Stderr, "last words")
		os.Exit(3)

	case "deaf":
		// Ignores SIGTERM, so only a kill stops it.
		signal.Ignore(syscall.SIGTERM)
		fmt.Println(`{"jsonrpc":"2.0","method":"ready","params":{}}`)
		time.Sleep(time.Hour)

	case "serve":
		// Answers every request, writing each one down first.
		record, _ := os.OpenFile(os.Getenv("SIGNAL_CLI_RECORD"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		s := bufio.NewScanner(os.Stdin)
		for s.Scan() {
			var req struct {
				ID     string `json:"id"`
				Method string `json:"method"`
			}
			_ = json.Unmarshal(s.Bytes(), &req)
			if record != nil {
				_, _ = record.Write(append(s.Bytes(), '\n'))
			}
			result := `{}`
			if req.Method == "getAttachment" {
				result = `{"data":"` + base64.StdEncoding.EncodeToString([]byte("picture")) + `"}`
			}
			fmt.Printf(`{"jsonrpc":"2.0","id":%q,"result":%s}`+"\n", req.ID, result)
		}
	}
	os.Exit(0)
}

// startHelper runs the stand-in above as this client's signal-cli.
func startHelper(t *testing.T, client *rpcClient, mode string) {
	t.Helper()
	t.Setenv("SIGNAL_CLI_HELPER", mode)
	if err := client.start(os.Args[0], []string{"-test.run=^TestHelperSignalCLI$"}); err != nil {
		t.Fatalf("could not start the stand-in signal-cli: %v", err)
	}
	t.Cleanup(client.stop)
}

// recordedRequests reads back what the stand-in was asked.
func recordedRequests(t *testing.T, path string) []map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var req map[string]any
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			t.Fatalf("stand-in recorded a line that is not JSON: %q", line)
		}
		out = append(out, req)
	}
	return out
}

// A read receipt has to name the messages it is for. The host only says how
// far the conversation has been read, and a receipt for that position named a
// message that does not exist.
func TestMarkReadReceiptsTheMessagesThatArrived(t *testing.T) {
	record := filepath.Join(t.TempDir(), "requests")
	t.Setenv("SIGNAL_CLI_RECORD", record)

	b := testBridge()
	client := newRPCClient()
	startHelper(t, client, "serve")
	b.rpc = client

	markRead := func(chatID string, upTo int64) {
		b.handleMarkRead(context.Background(), call{ID: 1, Method: "markRead",
			Params: json.RawMessage(fmt.Sprintf(`{"chatId":%q,"upTo":%d}`, chatID, upTo))})
	}

	captureEvents(t, func() {
		ada := envelope{SourceUUID: "uuid-ada"}
		b.onDataMessage(ada, &dataMessage{Timestamp: 1000, Message: "one"}, false)
		b.onDataMessage(ada, &dataMessage{Timestamp: 2000, Message: "two"}, false)
		b.onDataMessage(ada, &dataMessage{Timestamp: 9000, Message: "after reading"}, false)
		markRead("dm:uuid-ada", 5000)
	})

	reqs := recordedRequests(t, record)
	if len(reqs) != 1 || reqs[0]["method"] != "sendReceipt" {
		t.Fatalf("expected one sendReceipt, got %+v", reqs)
	}
	params := reqs[0]["params"].(map[string]any)
	targets, _ := params["targetTimestamp"].([]any)
	if len(targets) != 2 || targets[0] != float64(1000) || targets[1] != float64(2000) {
		t.Errorf("receipt names %v, want the two messages read: [1000 2000]", targets)
	}
	if params["recipient"] != "uuid-ada" || params["type"] != "read" {
		t.Errorf("receipt params %+v", params)
	}
	if refs := b.unread["dm:uuid-ada"]; len(refs) != 1 || refs[0].ts != 9000 {
		t.Errorf("the message after the read position must still be waiting, got %+v", refs)
	}

	// No receipt in a group, and none with receipts switched off -- but what
	// was read is forgotten either way, so no stale receipt follows later.
	captureEvents(t, func() {
		b.onDataMessage(envelope{SourceUUID: "uuid-ada"}, &dataMessage{
			Timestamp: 3000, Message: "group", GroupInfo: &groupInfo{GroupID: "abc=="},
		}, false)
		markRead("grp:abc==", 5000)
		b.settings["sendReadReceipts"] = false
		markRead("dm:uuid-ada", 10000)
	})
	if reqs := recordedRequests(t, record); len(reqs) != 1 {
		t.Errorf("sent receipts it should not have: %+v", reqs[1:])
	}
	if len(b.unread) != 0 {
		t.Errorf("read messages still remembered: %+v", b.unread)
	}
}

// The attachment that lands later is the same message again, so it goes out as
// a batch: a second message event would be a second announcement.
func TestAutoDownloadSendsTheMessageAgainAsABatch(t *testing.T) {
	b := testBridge()
	b.settings["autoDownloadMedia"] = true
	b.mediaDir = t.TempDir()
	client := newRPCClient()
	startHelper(t, client, "serve")
	b.rpc = client

	msg := messageObj{ID: "uuid-ada:1000", ChatID: "dm:uuid-ada", TS: 1000, Kind: "image", Text: "look", MediaRef: "att1", FileSize: 10}
	frames := captureEvents(t, func() { b.autoDownload(msg) })

	if len(frames) != 1 || frames[0]["event"] != "messages" {
		t.Fatalf("expected one messages batch, got %+v", frames)
	}
	got := frames[0]["messages"].([]any)[0].(map[string]any)
	if got["id"] != msg.ID || got["mediaPath"] != filepath.Join(b.mediaDir, "att1") || got["text"] != "look" {
		t.Errorf("re-sent message %+v", got)
	}
}

// signal-cli dying on its own has to be reported -- the bridge exits on it, so
// the host restarts both -- and the last thing it wrote has to be read first:
// that is the line that says why.
func TestSignalCLIDyingOnItsOwnIsReported(t *testing.T) {
	client := newRPCClient()
	reported := make(chan error, 1)
	client.onExit = func(err error) { reported <- err }

	frames := captureEvents(t, func() {
		startHelper(t, client, "die")
		select {
		case err := <-reported:
			if err == nil {
				t.Error("exit status 3 was reported as success")
			}
		case <-time.After(30 * time.Second):
			t.Fatal("signal-cli exiting on its own was never reported")
		}
	})

	found := false
	for _, f := range frames {
		if text, _ := f["text"].(string); f["event"] == "log" && strings.HasSuffix(text, "last words") {
			found = true
		}
	}
	if !found {
		t.Error("signal-cli's last line on stderr was lost before its exit was reported")
	}
}

// Stopping signal-cli on purpose is not it dying, and one that honours SIGTERM
// is not made to wait for the kill.
func TestStoppingSignalCLIIsNotReportedAsDying(t *testing.T) {
	client := newRPCClient()
	reported := make(chan error, 1)
	client.onExit = func(err error) { reported <- err }
	startHelper(t, client, "serve")

	begun := time.Now()
	client.stop()
	if waited := time.Since(begun); waited >= stopGrace {
		t.Errorf("stop took %v; SIGTERM should have been enough", waited)
	}
	select {
	case <-client.exited:
	case <-time.After(30 * time.Second):
		t.Fatal("signal-cli did not exit")
	}
	select {
	case err := <-reported:
		t.Errorf("a stop that was asked for was reported as signal-cli dying: %v", err)
	case <-time.After(200 * time.Millisecond):
	}
}

// One that ignores SIGTERM is killed once the grace period is up.
func TestStopKillsSignalCLIThatIgnoresSIGTERM(t *testing.T) {
	previous := stopGrace
	stopGrace = 300 * time.Millisecond
	t.Cleanup(func() { stopGrace = previous })

	client := newRPCClient()
	ready := make(chan struct{}, 1)
	client.onNotify = func(method string, _ json.RawMessage) {
		if method == "ready" {
			select {
			case ready <- struct{}{}:
			default:
			}
		}
	}
	startHelper(t, client, "deaf")
	select {
	case <-ready:
	case <-time.After(30 * time.Second):
		t.Fatal("the stand-in never started")
	}

	begun := time.Now()
	client.stop()
	if waited := time.Since(begun); waited < stopGrace {
		t.Errorf("stop returned after %v, before the grace period, from a process that ignored SIGTERM", waited)
	}
	select {
	case <-client.exited:
	case <-time.After(30 * time.Second):
		t.Fatal("a signal-cli that ignores SIGTERM was never killed")
	}
}
