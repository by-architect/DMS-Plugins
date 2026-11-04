package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
	"maunium.net/go/mautrix/pushrules"
)

// ---------------------------------------------------------------- fakes

// fakeHistory answers /messages from pages keyed by the token they start at,
// and records what it was asked.
type fakeHistory struct {
	pages   map[string]*mautrix.RespMessages
	found   *mautrix.RespTimestampToEvent
	findErr error
	context *mautrix.RespContext
	asked   []string
}

func (f *fakeHistory) Messages(ctx context.Context, roomID id.RoomID, from, to string, dir mautrix.Direction, filter *mautrix.FilterPart, limit int) (*mautrix.RespMessages, error) {
	f.asked = append(f.asked, "messages:"+from)
	if resp, ok := f.pages[from]; ok {
		return resp, nil
	}
	return &mautrix.RespMessages{}, nil
}

func (f *fakeHistory) TimestampToEvent(ctx context.Context, roomID id.RoomID, ts time.Time, dir mautrix.Direction) (*mautrix.RespTimestampToEvent, error) {
	f.asked = append(f.asked, "timestamp")
	if f.findErr != nil {
		return nil, f.findErr
	}
	return f.found, nil
}

func (f *fakeHistory) Context(ctx context.Context, roomID id.RoomID, eventID id.EventID, filter *mautrix.FilterPart, limit int) (*mautrix.RespContext, error) {
	f.asked = append(f.asked, "context:"+string(eventID))
	return f.context, nil
}

func textEvent(eventID string, sender id.UserID, ts int64, body string) *event.Event {
	evt := &event.Event{ID: id.EventID(eventID), RoomID: testRoom, Sender: sender, Timestamp: ts, Type: event.EventMessage}
	evt.Content.Parsed = &event.MessageEventContent{MsgType: event.MsgText, Body: body}
	return evt
}

func framesNamed(frames []map[string]any, name string) []map[string]any {
	var out []map[string]any
	for _, f := range frames {
		if f["event"] == name {
			out = append(out, f)
		}
	}
	return out
}

func batchIDs(frame map[string]any) []string {
	var out []string
	msgs, _ := frame["messages"].([]any)
	for _, m := range msgs {
		if obj, ok := m.(map[string]any); ok {
			id, _ := obj["id"].(string)
			out = append(out, id)
		}
	}
	return out
}

// ---------------------------------------------------------------- history

// Scrolling up carries on from where the last page stopped: the token is used
// as it is, everything it returns goes out as one backfill batch, oldest
// first, and the place it got to is kept for next time.
func TestBackfillCarriesOnFromTheLastPage(t *testing.T) {
	b := testBridge()
	b.room(testRoom).Members[testAda] = "Ada"
	b.updateRoom(testRoom, func(info *roomInfo) { info.BackfillToken, info.BackfillTS = "t1", 5000 })

	client := &fakeHistory{pages: map[string]*mautrix.RespMessages{
		"t1": {
			Chunk: []*event.Event{textEvent("$b", testAda, 4000, "second"), textEvent("$a", testAda, 3000, "first")},
			End:   "t2",
		},
	}}

	var more bool
	frames := captureEvents(t, func() {
		var err error
		more, err = b.backfill(context.Background(), client, testRoom, 5000, 2)
		if err != nil {
			t.Fatal(err)
		}
	})

	if !more {
		t.Error("a page with a token after it is not the beginning")
	}
	if len(client.asked) != 1 || client.asked[0] != "messages:t1" {
		t.Errorf("asked %v, want only the page after the stored token", client.asked)
	}
	batches := framesNamed(frames, "messages")
	if len(batches) != 1 || batches[0]["backfill"] != true {
		t.Fatalf("want one backfill batch, got %+v", frames)
	}
	if got := batchIDs(batches[0]); strings.Join(got, ",") != "$a,$b" {
		t.Errorf("batch = %v, want oldest first", got)
	}
	if info := b.room(testRoom); info.BackfillToken != "t2" || info.BackfillTS != 3000 {
		t.Errorf("kept token %q at %d, want t2 at 3000", info.BackfillToken, info.BackfillTS)
	}
}

// With no token for the moment -- the first time a room is scrolled past what
// was stored before this version -- the moment is looked up. The event found
// lies behind the token it gives, so it is delivered too.
func TestBackfillLooksTheMomentUp(t *testing.T) {
	b := testBridge()
	found := textEvent("$found", testAda, 4500, "found")
	client := &fakeHistory{
		found:   &mautrix.RespTimestampToEvent{EventID: "$found"},
		context: &mautrix.RespContext{Start: "ctx", Event: found},
		pages: map[string]*mautrix.RespMessages{
			"ctx": {Chunk: []*event.Event{textEvent("$older", testAda, 4000, "older")}, End: "deeper"},
		},
	}

	frames := captureEvents(t, func() {
		if _, err := b.backfill(context.Background(), client, testRoom, 5000, 50); err != nil {
			t.Fatal(err)
		}
	})

	if len(client.asked) < 3 || client.asked[0] != "timestamp" || client.asked[1] != "context:$found" || client.asked[2] != "messages:ctx" {
		t.Errorf("asked %v", client.asked)
	}
	batches := framesNamed(frames, "messages")
	if len(batches) != 1 || strings.Join(batchIDs(batches[0]), ",") != "$older,$found" {
		t.Errorf("want the found event delivered with the page, got %+v", frames)
	}
}

// A homeserver without timestamp lookup is walked back from the newest event,
// past what is already stored.
func TestBackfillWalksBackWithoutTimestampLookup(t *testing.T) {
	b := testBridge()
	client := &fakeHistory{
		findErr: errors.New("M_UNRECOGNIZED"),
		pages: map[string]*mautrix.RespMessages{
			"": {Chunk: []*event.Event{textEvent("$new", testAda, 9000, "already stored"), textEvent("$old", testAda, 1000, "wanted")}, End: "next"},
		},
	}

	frames := captureEvents(t, func() {
		if _, err := b.backfill(context.Background(), client, testRoom, 5000, 50); err != nil {
			t.Fatal(err)
		}
	})

	batches := framesNamed(frames, "messages")
	if len(batches) != 1 || strings.Join(batchIDs(batches[0]), ",") != "$old" {
		t.Errorf("want only what is older than asked for, got %+v", frames)
	}
}

// The homeserver finding nothing before the moment is the beginning, said at
// once rather than found by walking the whole room back.
func TestNothingBeforeTheMomentIsTheBeginning(t *testing.T) {
	b := testBridge()
	client := &fakeHistory{findErr: mautrix.MNotFound}

	var more bool
	captureEvents(t, func() {
		more, _ = b.backfill(context.Background(), client, testRoom, 5000, 50)
	})
	if more || !b.historyEnded(testRoom) {
		t.Errorf("more = %v, ended = %v; want the beginning recorded", more, b.historyEnded(testRoom))
	}
	for _, asked := range client.asked {
		if strings.HasPrefix(asked, "messages:") {
			t.Errorf("walked the room anyway: %v", client.asked)
		}
	}
}

// The beginning of a room is recorded, and asking again does not go to the
// homeserver at all.
func TestBackfillRemembersTheBeginning(t *testing.T) {
	b := testBridge()
	b.updateRoom(testRoom, func(info *roomInfo) { info.BackfillToken, info.BackfillTS = "t1", 5000 })
	client := &fakeHistory{pages: map[string]*mautrix.RespMessages{
		"t1": {Chunk: []*event.Event{textEvent("$first", testAda, 100, "hello")}},
	}}

	var more bool
	captureEvents(t, func() {
		more, _ = b.backfill(context.Background(), client, testRoom, 5000, 50)
	})
	if more {
		t.Error("a page with no token after it is the beginning")
	}
	if !b.historyEnded(testRoom) {
		t.Fatal("the beginning was not remembered")
	}

	frames := captureEvents(t, func() {
		raw, _ := json.Marshal(map[string]any{"chatId": string(testRoom), "before": 100, "limit": 50})
		b.handleHistory(context.Background(), call{ID: 7, Method: "history", Params: raw})
	})
	if len(frames) != 1 || frames[0]["ok"] != true {
		t.Fatalf("want a straight answer, got %+v", frames)
	}
	result, _ := frames[0]["result"].(map[string]any)
	if result["hasMore"] != false {
		t.Errorf("hasMore = %v, want false", result["hasMore"])
	}
}

// What history holds that this device cannot decrypt yet is shown as waiting
// and written down, like a message the sync could not decrypt, so a key that
// turns up later fills it in.
func TestBackfillShowsUndecryptableHistoryAsWaiting(t *testing.T) {
	b := testBridge()
	b.waiting = newWaitingStore("", testSelf)

	enc := &event.Event{ID: "$secret", RoomID: testRoom, Sender: testAda, Timestamp: 2000, Type: event.EventEncrypted}
	enc.Content.Parsed = &event.EncryptedEventContent{Algorithm: id.AlgorithmMegolmV1, SessionID: "sess1"}

	var frames []map[string]any
	frames = captureEvents(t, func() {
		b.deliverHistory(context.Background(), testRoom, []*event.Event{enc}, nil, true)
	})

	batches := framesNamed(frames, "messages")
	if len(batches) != 1 {
		t.Fatalf("want one batch, got %+v", frames)
	}
	row := batches[0]["messages"].([]any)[0].(map[string]any)
	if row["kind"] != "system" || row["text"] != waitingText {
		t.Errorf("row = %+v, want a waiting placeholder", row)
	}
	if got := b.waiting.count(); got != 1 {
		t.Errorf("%d events waiting, want the one written down", got)
	}
}

// A message deleted before it was paged in keeps its place as a deletion; an
// encrypted event deleted loses even whether it was a message, and is left out.
func TestBackfillDeletedMessages(t *testing.T) {
	b := testBridge()
	plain := textEvent("$gone", testAda, 1000, "")
	plain.Unsigned.RedactedBecause = &event.Event{ID: "$redaction"}
	sealed := &event.Event{ID: "$sealed", RoomID: testRoom, Sender: testAda, Timestamp: 1100, Type: event.EventEncrypted}
	sealed.Unsigned.RedactedBecause = &event.Event{ID: "$redaction2"}

	frames := captureEvents(t, func() {
		b.deliverHistory(context.Background(), testRoom, []*event.Event{plain, sealed}, nil, true)
	})

	batches := framesNamed(frames, "messages")
	if len(batches) != 1 {
		t.Fatalf("want one batch, got %+v", frames)
	}
	rows := batches[0]["messages"].([]any)
	if len(rows) != 1 || rows[0].(map[string]any)["kind"] != "deleted" {
		t.Errorf("rows = %+v, want one deletion", rows)
	}
}

// Somebody who left the room long ago is named as they were then, from the
// member state the page came with -- without joining the room's member list,
// where they would start naming the room.
func TestBackfillNamesSendersWhoHaveLeft(t *testing.T) {
	b := testBridge()
	gone := id.UserID("@gone:example.org")
	member := &event.Event{Type: event.StateMember, StateKey: ptrString(string(gone))}
	member.Content.Parsed = &event.MemberEventContent{Membership: event.MembershipJoin, Displayname: "Old Friend"}

	frames := captureEvents(t, func() {
		b.deliverHistory(context.Background(), testRoom, []*event.Event{textEvent("$1", gone, 1000, "hi")}, []*event.Event{member}, true)
	})

	row := framesNamed(frames, "messages")[0]["messages"].([]any)[0].(map[string]any)
	if row["senderName"] != "Old Friend" {
		t.Errorf("senderName = %v", row["senderName"])
	}
	if _, joined := b.room(testRoom).Members[gone]; joined {
		t.Error("a former member was put back in the room's member list")
	}
}

func ptrString(s string) *string { return &s }

// ---------------------------------------------------------------- the gaps

// A limited sync in a room this device knew is a gap to fill; the first sync,
// limited by its nature, is not -- but it is where each room's first walk back
// starts.
func TestNotePaginationFindsGaps(t *testing.T) {
	b := testBridge()
	b.updateRoom(testRoom, func(info *roomInfo) { info.LastEventTS = 1000 })

	resp := &mautrix.RespSync{}
	resp.Rooms.Join = map[id.RoomID]*mautrix.SyncJoinedRoom{
		testRoom: {Timeline: mautrix.SyncTimeline{
			SyncEventsList: mautrix.SyncEventsList{Events: []*event.Event{textEvent("$n", testAda, 9000, "new")}},
			Limited:        true,
			PrevBatch:      "gap-token",
		}},
	}

	if gaps := b.notePagination(resp, ""); len(gaps) != 0 {
		t.Errorf("an initial sync made gaps: %+v", gaps)
	}
	if info := b.room(testRoom); info.BackfillToken != "gap-token" || info.BackfillTS != 9000 {
		t.Errorf("first walk starts at %q/%d", info.BackfillToken, info.BackfillTS)
	}

	gaps := b.notePagination(resp, "s123")
	if len(gaps) != 1 || gaps[0].token != "gap-token" || gaps[0].since != 1000 {
		t.Errorf("gaps = %+v", gaps)
	}
}

// Filling a gap pages back until it reaches what was already here, and sends
// what lay between as an ordinary batch -- it arrived while nobody was looking,
// so it may well be unread.
func TestGapIsFilledBackToWhatWasHere(t *testing.T) {
	b := testBridge()
	client := &fakeHistory{pages: map[string]*mautrix.RespMessages{
		"gap": {Chunk: []*event.Event{textEvent("$m3", testAda, 3000, "c"), textEvent("$m2", testAda, 2000, "b")}, End: "gap2"},
		"gap2": {Chunk: []*event.Event{textEvent("$m1", testAda, 1500, "a"), textEvent("$had", testAda, 1000, "already here")}, End: "gap3"},
	}}

	var n int
	frames := captureEvents(t, func() {
		n, _ = b.walkGap(context.Background(), client, gapJob{roomID: testRoom, token: "gap", since: 1000})
	})

	if n != 3 {
		t.Errorf("filled %d, want 3", n)
	}
	if len(client.asked) != 2 {
		t.Errorf("asked %v, want it to stop at what was here", client.asked)
	}
	batch := framesNamed(frames, "messages")[0]
	if _, marked := batch["backfill"]; marked {
		t.Error("a gap is not backfill: what it holds can be unread")
	}
	if strings.Join(batchIDs(batch), ",") != "$m1,$m2,$m3" {
		t.Errorf("batch = %v", batchIDs(batch))
	}
}

// ---------------------------------------------------------------- reactions, edits, typing

func reactionEvent(eventID string, sender id.UserID, target id.EventID, key string) *event.Event {
	evt := &event.Event{ID: id.EventID(eventID), RoomID: testRoom, Sender: sender, Timestamp: 1234, Type: event.EventReaction}
	evt.Content.Parsed = &event.ReactionEventContent{RelatesTo: event.RelatesTo{Type: event.RelAnnotation, EventID: target, Key: key}}
	return evt
}

func TestReactionsAreReported(t *testing.T) {
	b := testBridge()
	b.room(testRoom).Members[testAda] = "Ada"

	frames := captureEvents(t, func() {
		b.onReaction(context.Background(), reactionEvent("$r", testAda, "$msg", "👍"))
	})
	if len(frames) != 1 || frames[0]["event"] != "reaction" {
		t.Fatalf("frames = %+v", frames)
	}
	r := frames[0]["reaction"].(map[string]any)
	if r["messageId"] != "$msg" || r["key"] != "👍" || r["senderName"] != "Ada" || r["id"] != "$r" {
		t.Errorf("reaction = %+v", r)
	}

	// An initial sync's reactions are history, held with its messages.
	initial := context.WithValue(context.Background(), mautrix.SyncTokenContextKey, "")
	frames = captureEvents(t, func() {
		b.onReaction(initial, reactionEvent("$r2", testAda, "$msg", "🎉"))
	})
	if len(frames) != 0 {
		t.Errorf("an initial sync's reaction went out on its own: %+v", frames)
	}
	frames = captureEvents(t, func() { b.flushHistory() })
	if batches := framesNamed(frames, "reactions"); len(batches) != 1 {
		t.Errorf("held reactions were not flushed: %+v", frames)
	}
}

func TestEditsCarryWhenTheyWereMade(t *testing.T) {
	b := testBridge()
	content := &event.MessageEventContent{
		MsgType:    event.MsgText,
		Body:       "* fixed",
		NewContent: &event.MessageEventContent{MsgType: event.MsgText, Body: "fixed"},
		RelatesTo:  (&event.RelatesTo{}).SetReplace("$orig"),
	}
	evt := textEvent("$edit", testAda, 7000, "")
	evt.Content.Parsed = content

	msg, edit := b.messageFor(evt, content)
	if !edit || msg.ID != "$orig" || msg.Text != "fixed" || msg.EditedTS != 7000 {
		t.Errorf("edit = %v, msg = %+v", edit, msg)
	}
}

// What an edit sends is what Element sends: the new text as m.new_content, a
// replace relation to the original, and a "* " fallback for old clients.
func TestSendEditShape(t *testing.T) {
	b := testBridge()
	sender := &fakeSender{}
	if _, err := b.sendEdit(context.Background(), sender, testRoom, "$orig", "**bold** now"); err != nil {
		t.Fatal(err)
	}
	if len(sender.sent) != 1 {
		t.Fatalf("sent %d events", len(sender.sent))
	}
	content := sender.sent[0]
	if content.RelatesTo == nil || content.RelatesTo.Type != event.RelReplace || content.RelatesTo.EventID != "$orig" {
		t.Errorf("relation = %+v", content.RelatesTo)
	}
	if content.NewContent == nil || content.NewContent.Body != "**bold** now" || content.NewContent.FormattedBody == "" {
		t.Errorf("new content = %+v", content.NewContent)
	}
	if !strings.HasPrefix(content.Body, "* ") {
		t.Errorf("fallback body = %q", content.Body)
	}
}

func TestTypingLeavesUsOut(t *testing.T) {
	b := testBridge()
	b.room(testRoom).Members[testAda] = "Ada"

	evt := &event.Event{RoomID: testRoom, Type: event.EphemeralEventTyping}
	evt.Content.Parsed = &event.TypingEventContent{UserIDs: []id.UserID{testSelf, testAda}}

	frames := captureEvents(t, func() { b.onTyping(context.Background(), evt) })
	if len(frames) != 1 {
		t.Fatalf("frames = %+v", frames)
	}
	users, _ := frames[0]["users"].([]any)
	if len(users) != 1 || users[0] != "Ada" {
		t.Errorf("users = %v", users)
	}
}

// ---------------------------------------------------------------- notification settings

const testRules = `{
  "override": [
    {"rule_id": "!muted:example.org", "enabled": true, "default": false, "actions": [],
     "conditions": [{"kind": "event_match", "key": "room_id", "pattern": "!muted:example.org"}]},
    {"rule_id": ".m.rule.is_user_mention", "enabled": true, "default": true,
     "actions": ["notify", {"set_tweak": "highlight"}],
     "conditions": [{"kind": "event_property_contains", "key": "content.m\\.mentions.user_ids", "value": "@me:example.org"}]}
  ],
  "room": [{"rule_id": "!quiet:example.org", "enabled": true, "default": false, "actions": []}],
  "underride": [
    {"rule_id": ".m.rule.message", "enabled": true, "default": true, "actions": ["notify"],
     "conditions": [{"kind": "event_match", "key": "type", "pattern": "m.room.message"}]}
  ]
}`

func loadRules(t *testing.T) *pushrules.PushRuleset {
	t.Helper()
	var rules pushrules.PushRuleset
	if err := json.Unmarshal([]byte(testRules), &rules); err != nil {
		t.Fatal(err)
	}
	return &rules
}

func wireEvent(t *testing.T, raw string) *event.Event {
	t.Helper()
	var evt event.Event
	if err := json.Unmarshal([]byte(raw), &evt); err != nil {
		t.Fatal(err)
	}
	_ = evt.Content.ParseRaw(evt.Type)
	return &evt
}

// Judged as the homeserver judges it for a phone: an ordinary message notifies,
// one in a room set to mentions only does not -- unless it mentions us, which
// is a highlight -- and nothing in a muted room does.
func TestNotificationHintsFollowThePushRules(t *testing.T) {
	b := testBridge()

	plain := func(room string) *event.Event {
		return wireEvent(t, `{"type":"m.room.message","event_id":"$1","room_id":"`+room+`","sender":"@ada:example.org","origin_server_ts":1,"content":{"msgtype":"m.text","body":"hi"}}`)
	}
	mention := wireEvent(t, `{"type":"m.room.message","event_id":"$2","room_id":"!quiet:example.org","sender":"@ada:example.org","origin_server_ts":1,"content":{"msgtype":"m.text","body":"hi me","m.mentions":{"user_ids":["@me:example.org"]}}}`)

	if silent, highlight := b.notificationHints(plain("!quiet:example.org")); silent || highlight {
		t.Error("with no rules known, the host's own settings should decide alone")
	}

	b.pushRules = loadRules(t)

	cases := []struct {
		name              string
		evt               *event.Event
		silent, highlight bool
	}{
		{"an ordinary room", plain("!room:example.org"), false, false},
		{"a room set to mentions only", plain("!quiet:example.org"), true, false},
		{"a mention there", mention, false, true},
		{"a muted room", plain("!muted:example.org"), true, false},
	}
	for _, c := range cases {
		silent, highlight := b.notificationHints(c.evt)
		if silent != c.silent || highlight != c.highlight {
			t.Errorf("%s: silent=%v highlight=%v, want %v %v", c.name, silent, highlight, c.silent, c.highlight)
		}
	}

	b.settings = map[string]any{"useMatrixNotifications": false}
	if silent, _ := b.notificationHints(plain("!muted:example.org")); silent {
		t.Error("turned off, the rules should not decide anything")
	}
}

// Only a change is reported: the rooms the rules mute the first time they are
// seen, and afterwards whatever is muted or unmuted elsewhere. A room merely
// not muted on Matrix is never reported, so a mute set here is left alone.
func TestReportMutesSaysOnlyWhatChanged(t *testing.T) {
	b := testBridge()
	muted, quiet := id.RoomID("!muted:example.org"), id.RoomID("!quiet:example.org")
	b.room(muted)
	b.room(quiet)
	b.pushRules = loadRules(t)

	frames := captureEvents(t, b.reportMutes)
	if len(frames) != 1 {
		t.Fatalf("frames = %+v", frames)
	}
	chat := frames[0]["chat"].(map[string]any)
	if chat["id"] != string(muted) || chat["muted"] != true {
		t.Errorf("chat = %+v", chat)
	}

	if frames = captureEvents(t, b.reportMutes); len(frames) != 0 {
		t.Errorf("nothing changed, yet %+v", frames)
	}

	b.pushRules = &pushrules.PushRuleset{}
	frames = captureEvents(t, b.reportMutes)
	if len(frames) != 1 || frames[0]["chat"].(map[string]any)["muted"] != false {
		t.Errorf("an unmute elsewhere should be reported: %+v", frames)
	}
}

type fakeRules struct {
	put, deleted []string
	deleteErr    error
	req          *mautrix.ReqPutPushRule
}

func (f *fakeRules) PutPushRule(ctx context.Context, scope string, kind pushrules.PushRuleType, ruleID string, req *mautrix.ReqPutPushRule) error {
	f.put = append(f.put, string(kind)+":"+ruleID)
	f.req = req
	return nil
}

func (f *fakeRules) DeletePushRule(ctx context.Context, scope string, kind pushrules.PushRuleType, ruleID string) error {
	f.deleted = append(f.deleted, string(kind)+":"+ruleID)
	return f.deleteErr
}

// A mute set here is the rule Element's Mute writes; lifting one that was never
// set on Matrix is not a failure.
func TestSetRoomMutedWritesElementsRule(t *testing.T) {
	rules := &fakeRules{}
	if err := setRoomMuted(context.Background(), rules, testRoom, true); err != nil {
		t.Fatal(err)
	}
	if len(rules.put) != 1 || rules.put[0] != "override:"+string(testRoom) {
		t.Errorf("put = %v", rules.put)
	}
	if rules.req == nil || len(rules.req.Actions) != 0 || len(rules.req.Conditions) != 1 ||
		rules.req.Conditions[0].Key != "room_id" || rules.req.Conditions[0].Pattern != string(testRoom) {
		t.Errorf("rule = %+v", rules.req)
	}
	if raw, _ := json.Marshal(rules.req); !strings.Contains(string(raw), `"actions":[]`) {
		t.Errorf("the rule must say no actions, not leave them out: %s", raw)
	}

	rules.deleteErr = mautrix.MNotFound
	if err := setRoomMuted(context.Background(), rules, testRoom, false); err != nil {
		t.Errorf("unmuting a room not muted on Matrix failed: %v", err)
	}
}

// ---------------------------------------------------------------- starting chats

func TestWithServerCompletesAddresses(t *testing.T) {
	cases := map[string]string{
		"@ada":                "@ada:example.org",
		"#lobby":              "#lobby:example.org",
		"@ada:other.org":      "@ada:other.org",
		"!opaqueRoomIdNoHost": "!opaqueRoomIdNoHost",
	}
	for in, want := range cases {
		if got := withServer(in, testSelf); got != want {
			t.Errorf("withServer(%q) = %q, want %q", in, got, want)
		}
	}
}

// An existing direct chat is reopened rather than a second one started.
func TestExistingDirectIsFound(t *testing.T) {
	b := testBridge()
	dm := id.RoomID("!dm:example.org")
	b.updateRoom(dm, func(info *roomInfo) {
		info.IsDirect = true
		info.Members[testSelf] = "Me"
		info.Members[testAda] = "Ada"
	})
	group := id.RoomID("!group:example.org")
	b.updateRoom(group, func(info *roomInfo) {
		info.IsDirect = true
		info.Members[testAda] = "Ada"
		info.Members["@bea:example.org"] = "Bea"
	})

	if got := b.existingDirect(testAda); got != dm {
		t.Errorf("existingDirect = %q, want %q", got, dm)
	}
	if got := b.existingDirect("@nobody:example.org"); got != "" {
		t.Errorf("found %q for somebody with no chat", got)
	}
}

// ---------------------------------------------------------------- pictures

// A direct chat with no picture of its own looks like the person in it, once
// that picture has been fetched.
func TestDirectChatTakesThePersonsPicture(t *testing.T) {
	b := testBridge()
	b.mediaDir = t.TempDir()

	face := id.ContentURI{Homeserver: "example.org", FileID: "adaface"}
	b.updateRoom(testRoom, func(info *roomInfo) {
		info.IsDirect = true
		info.Members[testSelf] = "Me"
		info.Members[testAda] = "Ada"
		info.MemberAvatars[testAda] = face
	})

	path := b.avatarPath(face)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("png"), 0o600); err != nil {
		t.Fatal(err)
	}

	if got := b.roomAvatar(testRoom); got != path {
		t.Errorf("roomAvatar = %q, want %q", got, path)
	}
	if got := b.senderAvatar(testRoom, testAda); got != path {
		t.Errorf("senderAvatar = %q, want %q", got, path)
	}

	b.settings = map[string]any{"showAvatars": false}
	if got := b.roomAvatar(testRoom); got != "" {
		t.Errorf("pictures turned off, yet %q", got)
	}
}

func TestPicturesStayInTheirFolder(t *testing.T) {
	b := testBridge()
	b.mediaDir = "/cache/matrix"
	got := b.avatarPath(id.ContentURI{Homeserver: "../evil", FileID: "../../etc/passwd"})
	if !strings.HasPrefix(got, "/cache/matrix/avatars/") || strings.Count(got, "/") != 4 {
		t.Errorf("avatarPath escaped its folder: %q", got)
	}
}

func TestSavePictureRefusesWhatIsTooBig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "avatars", "big")
	if err := savePicture(path, strings.NewReader(strings.Repeat("x", avatarMaxBytes+10))); err == nil {
		t.Error("an oversized picture was saved")
	}
	if _, err := os.Stat(path); err == nil {
		t.Error("an oversized picture was left on disk")
	}
	if err := savePicture(path, strings.NewReader("ok")); err != nil {
		t.Errorf("a small picture was refused: %v", err)
	}
}

// ---------------------------------------------------------------- the rest

func TestLanesKeepOrderWithinARoom(t *testing.T) {
	send := func(room string) call {
		raw, _ := json.Marshal(map[string]any{"chatId": room})
		return call{Method: "send", Params: raw}
	}
	if laneFor(send("!a")) == laneFor(send("!b")) {
		t.Error("two rooms share a lane, so one's upload holds up the other")
	}
	edit := call{Method: "edit", Params: send("!a").Params}
	if laneFor(edit) != laneFor(send("!a")) {
		t.Error("an edit could overtake the message it corrects")
	}
	if laneFor(call{Method: "markRead", Params: send("!a").Params}) == laneFor(send("!a")) {
		t.Error("a read receipt waits behind an upload")
	}

	var l lanes
	done := make(chan int, 3)
	for i := 0; i < 3; i++ {
		l.run("same", func() { done <- i })
	}
	for want := 0; want < 3; want++ {
		if got := <-done; got != want {
			t.Fatalf("lane ran %d before %d", got, want)
		}
	}
}

func TestSignedOutAccountIsEmpty(t *testing.T) {
	b := newBridge()
	frames := captureEvents(t, b.emitAccount)
	if len(frames) != 1 || frames[0]["event"] != "account" || frames[0]["account"] != nil {
		t.Errorf("frames = %+v", frames)
	}
}

// Our own name is kept even in a room too big to keep its members: it is what
// a message naming us is matched against.
func TestOwnNameIsKeptInBigRooms(t *testing.T) {
	t.Setenv("DMS_MATRIX_DIR", t.TempDir())
	store, _ := newRoomStore()

	big := newRoomInfo()
	big.Name = "Big Room"
	big.Members[testSelf] = "Me Myself"
	for i := 0; i < maxStoredMembers+1; i++ {
		big.Members[id.UserID("@u"+string(rune('a'+i%26))+string(rune('a'+i/26))+":example.org")] = "Someone"
	}
	store.save(map[id.RoomID]*roomInfo{testRoom: big}, testSelf)

	got := store.load()[testRoom]
	if len(got.Members) != 1 || got.Members[testSelf] != "Me Myself" {
		t.Errorf("members = %v, want only our own name", got.Members)
	}
}
