package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"go.mau.fi/util/dbutil"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto"
	"maunium.net/go/mautrix/crypto/backup"
	"maunium.net/go/mautrix/crypto/olm"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// A session id is 43 characters, as megolm makes them.
const testSession = id.SessionID("sessionsessionsessionsessionsessionsession1")

func waitingBridge(t *testing.T) *bridge {
	t.Helper()
	t.Setenv("DMS_MATRIX_DIR", t.TempDir())
	b := testBridge()
	b.waiting = loadWaiting(testSelf)
	return b
}

// encryptedEvent is an m.room.encrypted event as the crypto helper hands it
// over when it cannot open it.
func encryptedEvent(eventID id.EventID, rel *event.RelatesTo) *event.Event {
	evt := &event.Event{
		ID:        eventID,
		RoomID:    testRoom,
		Sender:    testAda,
		Timestamp: 1700000000000,
		Type:      event.EventEncrypted,
	}
	evt.Content.Parsed = &event.EncryptedEventContent{
		Algorithm: id.AlgorithmMegolmV1,
		SessionID: testSession,
		SenderKey: "adakey",
		DeviceID:  "ADAPHONE",
		RelatesTo: rel,
	}
	return evt
}

func batchOf(t *testing.T, frames []map[string]any) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, f := range frames {
		if f["event"] != "messages" {
			continue
		}
		list, _ := f["messages"].([]any)
		for _, m := range list {
			out = append(out, m.(map[string]any))
		}
	}
	return out
}

func republished(frames []map[string]any, roomID id.RoomID) bool {
	for _, f := range frames {
		if f["event"] != "chats" {
			continue
		}
		chats, _ := f["chats"].([]any)
		for _, c := range chats {
			if chat, _ := c.(map[string]any); chat["id"] == string(roomID) {
				return true
			}
		}
	}
	return false
}

func waitingIDs(b *bridge) []id.EventID {
	var ids []id.EventID
	for _, w := range b.waiting.pending() {
		ids = append(ids, w.EventID)
	}
	return ids
}

// ---------------------------------------------------------------- placeholders

// A message that cannot be decrypted is shown as waiting rather than dropped:
// a system row under its own id, in its own room, at its own time -- so the
// real message lands on the same row when its key arrives.
func TestUndecryptableMessageShowsAsWaiting(t *testing.T) {
	b := waitingBridge(t)
	b.room(testRoom).Members[testAda] = "Ada"

	frames := captureEvents(t, func() {
		b.noteUndecryptable(encryptedEvent("$secret", nil), crypto.ErrNoSessionFound)
	})

	msgs := batchOf(t, frames)
	if len(frames) != 1 || len(msgs) != 1 {
		t.Fatalf("want one batch with the placeholder, got %+v", frames)
	}
	m := msgs[0]
	if m["id"] != "$secret" || m["chatId"] != string(testRoom) || m["kind"] != "system" || m["text"] != waitingText {
		t.Errorf("placeholder = %+v", m)
	}
	if ts, _ := m["ts"].(float64); int64(ts) != 1700000000000 {
		t.Errorf("ts = %v, want the event's own time in milliseconds", m["ts"])
	}
	if m["senderName"] != "Ada" {
		t.Errorf("sender name = %v", m["senderName"])
	}

	pending := b.waiting.pending()
	if len(pending) != 1 || pending[0].SessionID != testSession || !pending[0].Shown || pending[0].SenderKey != "adakey" {
		t.Errorf("remembered %+v", pending)
	}
}

// A first sync full of undecryptable messages goes out as one batch, with the
// rest of the history, rather than a frame each.
func TestWaitingPlaceholdersAreHeldUntilTheResponseIsRead(t *testing.T) {
	b := waitingBridge(t)
	b.setDispatching(true)

	frames := captureEvents(t, func() {
		b.noteUndecryptable(encryptedEvent("$one", nil), crypto.ErrNoSessionFound)
		b.noteUndecryptable(encryptedEvent("$two", nil), crypto.ErrNoSessionFound)
	})
	if len(frames) != 0 {
		t.Fatalf("placeholders went out mid-response: %+v", frames)
	}

	b.setDispatching(false)
	frames = captureEvents(t, b.flushHistory)
	if len(frames) != 1 || len(batchOf(t, frames)) != 2 {
		t.Errorf("want both placeholders in one batch, got %+v", frames)
	}
}

// A reaction or a verification step is nothing this bridge shows even when it
// can read it, and an edit lands on a message already there: none of them gets
// a placeholder row. The edit is still waited for, so it can be applied.
func TestReactionsAndEditsGetNoPlaceholder(t *testing.T) {
	b := waitingBridge(t)

	frames := captureEvents(t, func() {
		b.noteUndecryptable(encryptedEvent("$reaction", &event.RelatesTo{Type: event.RelAnnotation, EventID: "$x", Key: "👍"}), crypto.ErrNoSessionFound)
		b.noteUndecryptable(encryptedEvent("$verify", &event.RelatesTo{Type: event.RelReference, EventID: "$x"}), crypto.ErrNoSessionFound)
		b.noteUndecryptable(encryptedEvent("$edit", &event.RelatesTo{Type: event.RelReplace, EventID: "$x"}), crypto.ErrNoSessionFound)
	})
	if len(frames) != 0 {
		t.Fatalf("got rows for events that are not messages of their own: %+v", frames)
	}

	pending := b.waiting.pending()
	if len(pending) != 1 || pending[0].EventID != "$edit" || pending[0].Shown {
		t.Errorf("waiting = %+v, want only the edit, with no row shown", pending)
	}

	// A reply or a thread message is a message: it is shown.
	frames = captureEvents(t, func() {
		reply := &event.RelatesTo{InReplyTo: &event.InReplyTo{EventID: "$x"}}
		b.noteUndecryptable(encryptedEvent("$reply", reply), crypto.ErrNoSessionFound)
	})
	if len(batchOf(t, frames)) != 1 {
		t.Errorf("a reply got no placeholder: %+v", frames)
	}
}

// A failure no key can cure is said to be one, and not kept to be tried
// forever.
func TestFailureThatWillNotChangeIsNotKept(t *testing.T) {
	b := waitingBridge(t)

	cause := fmt.Errorf("%w 7", crypto.ErrDuplicateMessageIndex)
	frames := captureEvents(t, func() { b.noteUndecryptable(encryptedEvent("$replayed", nil), cause) })

	msgs := batchOf(t, frames)
	if len(msgs) != 1 || msgs[0]["text"] != undecryptableText {
		t.Errorf("want a row saying it cannot be decrypted, got %+v", frames)
	}
	if ids := waitingIDs(b); len(ids) != 0 {
		t.Errorf("kept %v", ids)
	}

	for _, err := range []error{crypto.ErrNoSessionFound, fmt.Errorf("decrypt: %w", olm.ErrUnknownMessageIndex), errNoEncryption} {
		if !worthRetrying(err) {
			t.Errorf("%v is cured by a key arriving, and should be retried", err)
		}
	}
}

// With encryption not running, nothing else would handle an encrypted event;
// it waits for a start that can decrypt it.
func TestEncryptedEventWithoutEncryptionWaits(t *testing.T) {
	b := waitingBridge(t)

	frames := captureEvents(t, func() {
		b.onEncryptedWithoutCrypto(context.Background(), encryptedEvent("$early", nil))
	})
	if msgs := batchOf(t, frames); len(msgs) != 1 || msgs[0]["text"] != waitingText {
		t.Errorf("got %+v", frames)
	}
	if ids := waitingIDs(b); len(ids) != 1 {
		t.Errorf("waiting = %v", ids)
	}
}

// ---------------------------------------------------------------- the list

// The list survives a restart, readable only by its owner: the events in it
// will not be delivered again, so a list held only in memory is placeholders
// nobody ever fills in.
func TestWaitingListSurvivesARestart(t *testing.T) {
	b := waitingBridge(t)
	captureEvents(t, func() { b.noteUndecryptable(encryptedEvent("$secret", nil), crypto.ErrNoSessionFound) })
	b.saveWaiting()

	path, _ := waitingPath()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("not written: %v", err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Errorf("mode = %o, want 600", mode)
	}

	again := loadWaiting(testSelf).pending()
	if len(again) != 1 || again[0].EventID != "$secret" || again[0].RoomID != testRoom || again[0].SessionID != testSession || !again[0].Shown {
		t.Errorf("reloaded %+v", again)
	}

	// Another account's list is not this one's to fill in.
	if other := loadWaiting("@someone:else.org").pending(); len(other) != 0 {
		t.Errorf("another account inherited %+v", other)
	}
}

// Past the cap the oldest go; one older than everything kept is not kept, and
// says it will not be tried rather than that it waits.
func TestWaitingListKeepsTheNewest(t *testing.T) {
	store := newWaitingStore("", testSelf)
	for i := 0; i < maxWaiting+5; i++ {
		store.add(waitingEvent{RoomID: testRoom, EventID: id.EventID(fmt.Sprintf("$e%04d", i)), SessionID: testSession, TS: int64(1000 + i)})
	}

	pending := store.pending()
	if len(pending) != maxWaiting {
		t.Fatalf("kept %d, want %d", len(pending), maxWaiting)
	}
	if pending[0].EventID != "$e0005" {
		t.Errorf("oldest kept = %s, want the five oldest gone", pending[0].EventID)
	}
	if store.add(waitingEvent{RoomID: testRoom, EventID: "$ancient", SessionID: testSession, TS: 1}) {
		t.Error("an event older than everything on a full list was kept")
	}
}

// A key arriving for something waiting wakes the retry; one nothing waits for
// does not.
func TestArrivingKeyWakesTheRetry(t *testing.T) {
	b := waitingBridge(t)
	captureEvents(t, func() { b.noteUndecryptable(encryptedEvent("$secret", nil), crypto.ErrNoSessionFound) })

	b.keyArrived("someothersessionsomeothersessionsomeothers1")
	select {
	case <-b.retryWake:
		t.Fatal("woken for a key nothing waits for")
	default:
	}

	b.keyArrived(testSession)
	select {
	case <-b.retryWake:
	default:
		t.Fatal("not woken for a key something waits for")
	}
	if fresh := b.waiting.takeFresh(); len(fresh) != 1 || fresh[0].EventID != "$secret" {
		t.Errorf("fresh = %+v", fresh)
	}
}

// A message deleted while it waits has nothing left to decrypt; filled in
// afterwards, it would come back.
func TestDeletedMessageStopsWaiting(t *testing.T) {
	b := waitingBridge(t)
	captureEvents(t, func() { b.noteUndecryptable(encryptedEvent("$secret", nil), crypto.ErrNoSessionFound) })

	redaction := &event.Event{RoomID: testRoom, Type: event.EventRedaction, Redacts: "$secret"}
	captureEvents(t, func() { b.onRedaction(context.Background(), redaction) })

	if ids := waitingIDs(b); len(ids) != 0 {
		t.Errorf("still waiting on %v", ids)
	}
}

// ---------------------------------------------------------------- retrying

type fakeEvents struct {
	events map[id.EventID][]byte
	err    error
	asked  int
}

// GetEvent hands back a fresh copy each time, unparsed, as the homeserver's
// answer arrives.
func (f *fakeEvents) GetEvent(_ context.Context, _ id.RoomID, eventID id.EventID) (*event.Event, error) {
	f.asked++
	if f.err != nil {
		return nil, f.err
	}
	raw, ok := f.events[eventID]
	if !ok {
		return nil, mautrix.HTTPError{RespError: &mautrix.RespError{ErrCode: "M_NOT_FOUND"}}
	}
	var evt event.Event
	if err := json.Unmarshal(raw, &evt); err != nil {
		return nil, err
	}
	return &evt, nil
}

// fakeDecrypter opens an event into what was planted for it.
type fakeDecrypter struct {
	plain map[id.EventID]*event.Event
	err   error
}

func (f *fakeDecrypter) Decrypt(_ context.Context, evt *event.Event) (*event.Event, error) {
	if f.err != nil {
		return nil, f.err
	}
	plain := f.plain[evt.ID]
	if plain == nil {
		return nil, fmt.Errorf("failed to decrypt megolm event: %w", crypto.ErrNoSessionFound)
	}
	plain.Mautrix.WasEncrypted = true
	return plain, nil
}

// haveKeys says every key is here.
type haveKeys struct{}

func (haveKeys) GetGroupSession(context.Context, id.RoomID, id.SessionID) (*crypto.InboundGroupSession, error) {
	return &crypto.InboundGroupSession{}, nil
}

func encryptedJSON(t *testing.T, eventID id.EventID) []byte {
	t.Helper()
	raw, err := json.Marshal(map[string]any{
		"event_id":         eventID,
		"room_id":          testRoom,
		"sender":           testAda,
		"type":             "m.room.encrypted",
		"origin_server_ts": 1700000000000,
		"content": map[string]any{
			"algorithm":  id.AlgorithmMegolmV1,
			"session_id": testSession,
			"ciphertext": "AwgAEhAAAAAAAAAAAAAAAAAAAAAA",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func decryptedAs(eventID id.EventID, evtType event.Type, content any) *event.Event {
	evt := &event.Event{ID: eventID, RoomID: testRoom, Sender: testAda, Timestamp: 1700000000000, Type: evtType}
	evt.Content.Parsed = content
	return evt
}

// retrySetup has events waiting, the homeserver holding them, and the keys
// that open them.
func retrySetup(t *testing.T, plain map[id.EventID]*event.Event, shown bool) (*bridge, retryKit, *fakeEvents) {
	t.Helper()
	b := waitingBridge(t)
	events := &fakeEvents{events: map[id.EventID][]byte{}}
	for eventID := range plain {
		events.events[eventID] = encryptedJSON(t, eventID)
		b.waiting.add(waitingEvent{RoomID: testRoom, EventID: eventID, SessionID: testSession, Sender: testAda, TS: 1700000000000, Shown: shown})
	}
	return b, retryKit{events: events, decrypt: &fakeDecrypter{plain: plain}, sessions: haveKeys{}}, events
}

// Once its key is here, the message goes out under its own id -- replacing the
// placeholder -- as history, and is no longer waited for.
func TestDecryptedMessageReplacesItsPlaceholder(t *testing.T) {
	plain := map[id.EventID]*event.Event{
		"$secret": decryptedAs("$secret", event.EventMessage, &event.MessageEventContent{MsgType: event.MsgText, Body: "the secret"}),
	}
	b, kit, _ := retrySetup(t, plain, true)

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })

	msgs := batchOf(t, frames)
	if len(msgs) != 1 || msgs[0]["id"] != "$secret" || msgs[0]["kind"] != "text" || msgs[0]["text"] != "the secret" {
		t.Fatalf("got %+v", frames)
	}
	for _, f := range frames {
		if f["event"] == "message" || f["event"] == "deleted" {
			t.Errorf("unexpected %v frame: %+v", f["event"], f)
		}
	}
	// The room again, so the host counts unread with the message in it.
	if !republished(frames, testRoom) {
		t.Errorf("the room was not republished: %+v", frames)
	}
	if ids := waitingIDs(b); len(ids) != 0 {
		t.Errorf("still waiting on %v", ids)
	}
}

// A photo with no caption carries no text, and the host keeps a row's old text
// when a redelivery brings none: the placeholder's words would stay under the
// photo. The row is cleared first, by the one thing that clears text.
func TestRecoveredAttachmentClearsThePlaceholderText(t *testing.T) {
	plain := map[id.EventID]*event.Event{
		"$photo": decryptedAs("$photo", event.EventMessage, &event.MessageEventContent{MsgType: event.MsgImage, Body: "a.png", URL: "mxc://example.org/img"}),
	}
	b, kit, _ := retrySetup(t, plain, true)

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })

	deletedAt, batchAt := -1, -1
	for i, f := range frames {
		switch f["event"] {
		case "deleted":
			if f["messageId"] == "$photo" && f["chatId"] == string(testRoom) {
				deletedAt = i
			}
		case "messages":
			batchAt = i
		}
	}
	if deletedAt < 0 || batchAt < 0 || deletedAt > batchAt {
		t.Fatalf("want the row cleared and then the photo, got %+v", frames)
	}
	if msgs := batchOf(t, frames); msgs[0]["kind"] != "image" || msgs[0]["text"] != nil {
		t.Errorf("photo = %+v", msgs[0])
	}
}

// A message with text needs no clearing: its text replaces the placeholder's.
func TestRecoveredTextIsNotDeletedFirst(t *testing.T) {
	plain := map[id.EventID]*event.Event{
		"$secret": decryptedAs("$secret", event.EventMessage, &event.MessageEventContent{MsgType: event.MsgText, Body: "words"}),
	}
	b, kit, _ := retrySetup(t, plain, true)

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })
	for _, f := range frames {
		if f["event"] == "deleted" {
			t.Errorf("a message with text was deleted first: %+v", frames)
		}
	}
}

// An edit decrypted late lands on the message it corrects, and adds no row of
// its own.
func TestRecoveredEditLandsOnTheMessageItEdits(t *testing.T) {
	edit := &event.MessageEventContent{
		MsgType:    event.MsgText,
		Body:       "* fixed",
		NewContent: &event.MessageEventContent{MsgType: event.MsgText, Body: "fixed"},
		RelatesTo:  &event.RelatesTo{Type: event.RelReplace, EventID: "$original"},
	}
	plain := map[id.EventID]*event.Event{"$edit": decryptedAs("$edit", event.EventMessage, edit)}
	b, kit, _ := retrySetup(t, plain, false)

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })

	msgs := batchOf(t, frames)
	if len(msgs) != 1 || msgs[0]["id"] != "$original" || msgs[0]["text"] != "fixed" {
		t.Errorf("got %+v", msgs)
	}
}

// Something that turns out to be nothing this bridge shows does not leave its
// placeholder waiting for ever.
func TestRecoveredNonMessageClosesItsPlaceholder(t *testing.T) {
	plain := map[id.EventID]*event.Event{
		"$call": decryptedAs("$call", event.Type{Type: "m.call.invite", Class: event.MessageEventType}, nil),
	}
	b, kit, _ := retrySetup(t, plain, true)

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })

	msgs := batchOf(t, frames)
	if len(msgs) != 1 || msgs[0]["id"] != "$call" || msgs[0]["kind"] != "unsupported" || msgs[0]["text"] != unshowableText {
		t.Errorf("got %+v", msgs)
	}
}

// A key that does not open the message leaves it waiting, and it is not
// fetched again every pass -- only when a better key arrives.
func TestStillUndecryptableKeepsWaiting(t *testing.T) {
	b, kit, events := retrySetup(t, map[id.EventID]*event.Event{"$secret": nil}, true)
	kit.decrypt = &fakeDecrypter{err: fmt.Errorf("failed to decrypt megolm event: %w", olm.ErrUnknownMessageIndex)}

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })
	if len(frames) != 0 {
		t.Errorf("sent %+v", frames)
	}
	if ids := waitingIDs(b); len(ids) != 1 {
		t.Fatalf("waiting = %v", ids)
	}

	captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })
	if events.asked != 1 {
		t.Errorf("fetched %d times, want once until a better key arrives", events.asked)
	}

	b.keyArrived(testSession)
	captureEvents(t, func() { b.retryPass(context.Background(), kit, false) })
	if events.asked != 2 {
		t.Errorf("fetched %d times, want again once a key arrived", events.asked)
	}
}

// A message deleted while it waited is said to be deleted -- the deletion can
// have reached the host before the placeholder did.
func TestDeletedWhileWaitingIsSaidAgain(t *testing.T) {
	b, kit, events := retrySetup(t, map[id.EventID]*event.Event{"$secret": nil}, true)
	raw, _ := json.Marshal(map[string]any{
		"event_id": "$secret", "room_id": testRoom, "sender": testAda, "type": "m.room.encrypted",
		"origin_server_ts": 1700000000000, "content": map[string]any{},
		"unsigned": map[string]any{"redacted_because": map[string]any{"type": "m.room.redaction", "sender": testAda}},
	})
	events.events["$secret"] = raw

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })

	if !hasFrame(frames, "deleted", string(testRoom)) || len(batchOf(t, frames)) != 0 {
		t.Errorf("got %+v", frames)
	}
	if ids := waitingIDs(b); len(ids) != 0 {
		t.Errorf("still waiting on %v", ids)
	}
}

// A failure no later key can cure ends the wait, and the placeholder says so.
func TestGivingUpSaysSo(t *testing.T) {
	b, kit, _ := retrySetup(t, map[id.EventID]*event.Event{"$secret": nil}, true)
	kit.decrypt = &fakeDecrypter{err: fmt.Errorf("%w 3", crypto.ErrDuplicateMessageIndex)}

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })

	msgs := batchOf(t, frames)
	if len(msgs) != 1 || msgs[0]["id"] != "$secret" || msgs[0]["kind"] != "system" || msgs[0]["text"] != undecryptableText {
		t.Errorf("got %+v", frames)
	}
	if ids := waitingIDs(b); len(ids) != 0 {
		t.Errorf("still waiting on %v", ids)
	}
}

// A homeserver that cannot be reached ends the pass and gives nothing up: the
// next pass tries the same events again.
func TestUnreachableHomeserverGivesNothingUp(t *testing.T) {
	plain := map[id.EventID]*event.Event{
		"$one": decryptedAs("$one", event.EventMessage, &event.MessageEventContent{MsgType: event.MsgText, Body: "1"}),
		"$two": decryptedAs("$two", event.EventMessage, &event.MessageEventContent{MsgType: event.MsgText, Body: "2"}),
	}
	b, kit, events := retrySetup(t, plain, true)
	events.err = mautrix.HTTPError{Message: "connection refused"}

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })
	if len(frames) != 0 {
		t.Errorf("sent %+v", frames)
	}
	if events.asked != 1 {
		t.Errorf("asked %d times, want the pass to stop at the first", events.asked)
	}
	if ids := waitingIDs(b); len(ids) != 2 {
		t.Fatalf("waiting = %v", ids)
	}

	events.err = nil
	frames = captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })
	if len(batchOf(t, frames)) != 2 {
		t.Errorf("the next pass did not try them again: %+v", frames)
	}
}

// A decrypted message never goes out ahead of a placeholder still held back
// for it, which would put itself back over the message.
func TestRecoveredMessageFollowsItsHeldPlaceholder(t *testing.T) {
	plain := map[id.EventID]*event.Event{
		"$secret": decryptedAs("$secret", event.EventMessage, &event.MessageEventContent{MsgType: event.MsgText, Body: "the secret"}),
	}
	b, kit, _ := retrySetup(t, plain, true)
	b.setDispatching(true)
	captureEvents(t, func() { b.noteUndecryptable(encryptedEvent("$secret", nil), crypto.ErrNoSessionFound) })

	frames := captureEvents(t, func() { b.retryPass(context.Background(), kit, true) })

	msgs := batchOf(t, frames)
	if len(msgs) != 2 || msgs[0]["text"] != waitingText || msgs[1]["text"] != "the secret" {
		t.Errorf("want the placeholder and then the message, got %+v", msgs)
	}
}

// ---------------------------------------------------------------- the real thing

// mautrixDecrypter opens events with a local encryption machine, as the
// crypto helper does over a real one.
type mautrixDecrypter struct{ mach *crypto.OlmMachine }

func (d mautrixDecrypter) Decrypt(ctx context.Context, evt *event.Event) (*event.Event, error) {
	return d.mach.DecryptMegolmEvent(ctx, evt)
}

// localMachine is an encryption machine over a throwaway store, with nothing
// that would reach a homeserver.
func localMachine(t *testing.T) *crypto.OlmMachine {
	t.Helper()
	ctx := context.Background()

	raw, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "crypto.db")+"?_pragma=foreign_keys(1)")
	if err != nil {
		t.Fatal(err)
	}
	raw.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = raw.Close() })
	db, err := dbutil.NewWithDB(raw, "sqlite3")
	if err != nil {
		t.Fatal(err)
	}

	store := crypto.NewSQLCryptoStore(db, dbutil.NoopLogger, "", "THISDEVICE", []byte("pickle"))
	if err := store.DB.Upgrade(ctx); err != nil {
		t.Fatalf("crypto store: %v", err)
	}
	client, err := mautrix.NewClient("https://example.invalid", testSelf, "token")
	if err != nil {
		t.Fatal(err)
	}
	client.DeviceID = "THISDEVICE"

	mach := crypto.NewOlmMachine(client, nil, store, mautrix.NewMemoryStateStore().(crypto.StateStore))
	mach.DisableDecryptKeyFetching = true
	if err := mach.Load(ctx); err != nil {
		t.Fatal(err)
	}
	return mach
}

// End to end, with real megolm: a message whose key has not arrived waits; a
// copy of the key that starts after it does not open it, and it goes on
// waiting; the whole key arriving wakes the retry, and the message replaces its
// placeholder.
func TestWaitingMessageIsDecryptedWhenItsKeyArrives(t *testing.T) {
	ctx := context.Background()
	b := waitingBridge(t)
	mach := localMachine(t)
	mach.SessionReceived = func(_ context.Context, _ id.RoomID, sessionID id.SessionID, _ uint32) {
		b.keyArrived(sessionID)
	}

	// Ada's phone encrypts a message with a session this device was never
	// given.
	outbound, err := olm.NewOutboundGroupSession()
	if err != nil {
		t.Fatal(err)
	}
	// The key as it is shared: before the first message, so it opens it.
	sessionKey := outbound.Key()
	payload, _ := json.Marshal(map[string]any{
		"room_id": testRoom,
		"type":    "m.room.message",
		"content": map[string]any{"msgtype": "m.text", "body": "the secret"},
	})
	ciphertext, err := outbound.Encrypt(payload)
	if err != nil {
		t.Fatal(err)
	}
	// The key as a device that joined after this message would be given it.
	lateKey := outbound.Key()
	wire, _ := json.Marshal(map[string]any{
		"event_id": "$secret", "room_id": testRoom, "sender": testAda, "type": "m.room.encrypted",
		"origin_server_ts": 1700000000000,
		"content": map[string]any{
			"algorithm":  id.AlgorithmMegolmV1,
			"session_id": outbound.ID(),
			"sender_key": "adakey",
			"ciphertext": string(ciphertext),
		},
	})
	events := &fakeEvents{events: map[id.EventID][]byte{"$secret": wire}}
	kit := retryKit{events: events, decrypt: mautrixDecrypter{mach}, sessions: mach.CryptoStore}

	// It arrives, and cannot be read.
	first, _ := events.GetEvent(ctx, testRoom, "$secret")
	_ = first.Content.ParseRaw(first.Type)
	if _, err := mach.DecryptMegolmEvent(ctx, first); !errors.Is(err, crypto.ErrNoSessionFound) {
		t.Fatalf("decrypting without the key: %v", err)
	}
	frames := captureEvents(t, func() { b.noteUndecryptable(first, crypto.ErrNoSessionFound) })
	if msgs := batchOf(t, frames); len(msgs) != 1 || msgs[0]["text"] != waitingText {
		t.Fatalf("no placeholder: %+v", frames)
	}

	// Nothing to do while the key is missing.
	if frames := captureEvents(t, func() { b.retryPass(ctx, kit, true) }); len(frames) != 0 {
		t.Fatalf("sent %+v without the key", frames)
	}

	keyArrives := func(key string) {
		t.Helper()
		inbound, err := crypto.NewInboundGroupSession("adakey", "adasigningkey", testRoom, key, 0, 0, nil, false)
		if err != nil {
			t.Fatal(err)
		}
		if err := mach.StoreGroupSession(ctx, inbound); err != nil {
			t.Fatal(err)
		}
		select {
		case <-b.retryWake:
		default:
			t.Fatal("the key arriving did not wake the retry")
		}
	}

	// A key that starts after the message: tried, and still waiting.
	keyArrives(lateKey)
	if frames := captureEvents(t, func() { b.retryPass(ctx, kit, false) }); len(frames) != 0 {
		t.Fatalf("sent %+v with a key that does not open it", frames)
	}
	if ids := waitingIDs(b); len(ids) != 1 {
		t.Fatalf("waiting = %v, want it kept for a better key", ids)
	}

	// The whole key arrives -- forwarded, restored from the backup.
	keyArrives(sessionKey)
	frames = captureEvents(t, func() { b.retryPass(ctx, kit, false) })
	msgs := batchOf(t, frames)
	if len(msgs) != 1 || msgs[0]["id"] != "$secret" || msgs[0]["text"] != "the secret" || msgs[0]["kind"] != "text" {
		t.Fatalf("got %+v", frames)
	}
	if ids := waitingIDs(b); len(ids) != 0 {
		t.Errorf("still waiting on %v", ids)
	}
}

// A device that is not verified asks nobody for keys: the account's other
// devices answer it with a refusal, which mautrix keeps as the key being
// withheld -- and then takes the key from nowhere, the backup included. The
// device marks itself as verified, which must not count.
func TestUnverifiedDeviceDoesNotAskForKeys(t *testing.T) {
	mach := localMachine(t)
	if mach.OwnIdentity().Trust != id.TrustStateVerified {
		t.Fatal("mautrix no longer marks its own device verified; crossSigned's copy is moot")
	}
	if crossSigned(context.Background(), mach) {
		t.Error("a device with no cross-signing at all counts as verified")
	}
}

// The backup key kept at verification comes back out of the encryption store
// as the same key, which is what lets the backup be asked again after a
// restart without the recovery key.
func TestBackupKeyIsKeptForLater(t *testing.T) {
	ctx := context.Background()
	mach := localMachine(t)
	if storedBackupKey(ctx, mach) != nil {
		t.Fatal("a backup key before one was kept")
	}

	key, err := backup.NewMegolmBackupKey()
	if err != nil {
		t.Fatal(err)
	}
	keepBackupKey(ctx, mach, key.Bytes())

	got := storedBackupKey(ctx, mach)
	if got == nil || !bytes.Equal(got.PublicKey().Bytes(), key.PublicKey().Bytes()) {
		t.Errorf("kept %v, got back %v", key.PublicKey(), got)
	}
}

// ---------------------------------------------------------------- old attachments

// An encrypted attachment stored before refs carried their key is opened by
// fetching its message again and taking the key from it.
func TestOldEncryptedAttachmentFindsItsKey(t *testing.T) {
	plaintext := []byte("the picture itself")
	file, ciphertext := encryptedAttachment(t, plaintext)

	plain := decryptedAs("$photo", event.EventMessage, &event.MessageEventContent{MsgType: event.MsgImage, Body: "a.png", File: file})
	events := &fakeEvents{events: map[id.EventID][]byte{"$photo": encryptedJSON(t, "$photo")}}
	dec := &fakeDecrypter{plain: map[id.EventID]*event.Event{"$photo": plain}}

	ref, err := legacyRef(context.Background(), events, dec, true, testRoom, "$photo", string(file.URL))
	if err != nil {
		t.Fatalf("legacyRef: %v", err)
	}
	_, key, err := parseMediaRef(ref)
	if err != nil || key == nil {
		t.Fatalf("ref %q carries no key: %v", ref, err)
	}

	path, err := saveAttachment(t.TempDir(), "enc", bytes.NewReader(ciphertext), key, 0)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if got, _ := os.ReadFile(path); !bytes.Equal(got, plaintext) {
		t.Errorf("saved %q, want the decrypted file", got)
	}
}

// What was sent unencrypted stays a plain download, and a ref that already
// carries its key is not looked up at all.
func TestAttachmentRefsThatNeedNoKey(t *testing.T) {
	plainEvent, _ := json.Marshal(map[string]any{
		"event_id": "$sticker", "room_id": testRoom, "sender": testAda, "type": "m.sticker",
		"origin_server_ts": 1700000000000,
		"content":          map[string]any{"body": "wave", "url": "mxc://example.org/sticker"},
	})
	events := &fakeEvents{events: map[id.EventID][]byte{"$sticker": plainEvent}}

	ref, err := legacyRef(context.Background(), events, nil, true, testRoom, "$sticker", "mxc://example.org/sticker")
	if err != nil || ref != "mxc://example.org/sticker" {
		t.Errorf("ref = %q, %v; want the plain URL back", ref, err)
	}

	file, _ := encryptedAttachment(t, []byte("x"))
	keyed, _ := json.Marshal(file)
	events.asked = 0
	if ref, err := legacyRef(context.Background(), events, nil, true, testRoom, "$photo", string(keyed)); err != nil || ref != string(keyed) {
		t.Errorf("a keyed ref came back as %q, %v", ref, err)
	}
	if events.asked != 0 {
		t.Error("a ref with its key fetched the message anyway")
	}
}

// Without the key, an attachment in an encrypted room is refused rather than
// saved as noise. In a room not known to be encrypted, a message that cannot
// be fetched is no reason not to try the plain download.
func TestOldEncryptedAttachmentWithoutItsKeyIsRefused(t *testing.T) {
	ctx := context.Background()
	const ref = "mxc://example.org/enc"
	events := &fakeEvents{events: map[id.EventID][]byte{"$photo": encryptedJSON(t, "$photo")}}

	if _, err := legacyRef(ctx, events, &fakeDecrypter{}, false, testRoom, "$photo", ref); err == nil {
		t.Error("an attachment whose message cannot be decrypted was handed over to download")
	}
	if _, err := legacyRef(ctx, events, nil, false, testRoom, "$photo", ref); err == nil {
		t.Error("with encryption not running, an encrypted message's attachment was handed over to download")
	}

	events.err = mautrix.HTTPError{Message: "connection refused"}
	if _, err := legacyRef(ctx, events, &fakeDecrypter{}, true, testRoom, "$photo", ref); err == nil {
		t.Error("in an encrypted room, an attachment was downloaded without its key")
	}
	if got, err := legacyRef(ctx, events, &fakeDecrypter{}, false, testRoom, "$photo", ref); err != nil || got != ref {
		t.Errorf("in a room not known to be encrypted got %q, %v; want the plain download", got, err)
	}
}
