package main

import (
	"context"
	"testing"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

func receiptEvent(roomID id.RoomID, user id.UserID, receiptType event.ReceiptType, at time.Time) *event.Event {
	content := event.ReceiptEventContent{
		id.EventID("$evt"): {
			receiptType: {user: event.ReadReceipt{Timestamp: at}},
		},
	}
	evt := &event.Event{RoomID: roomID, Type: event.EphemeralEventReceipt}
	evt.Content.Parsed = &content
	return evt
}

// Our own read receipt is how Matrix records what we have read anywhere -- on a
// phone, in Element. Reporting it is what stops a conversation read an hour ago
// coming back unread here, and notifying for messages already seen.
func TestOwnReceiptPublishesTheReadPosition(t *testing.T) {
	b := testBridge()
	read := time.UnixMilli(1700000000000)

	frames := captureEvents(t, func() {
		b.onReceipt(context.Background(), receiptEvent(testRoom, testSelf, event.ReceiptTypeRead, read))
	})

	if len(frames) != 1 || frames[0]["event"] != "chat" {
		t.Fatalf("expected the room to be republished, got %+v", frames)
	}
	chat, _ := frames[0]["chat"].(map[string]any)
	if ts, _ := chat["readUpTo"].(float64); int64(ts) != read.UnixMilli() {
		t.Errorf("readUpTo = %v, want %d", chat["readUpTo"], read.UnixMilli())
	}

	// A private receipt is still us reading the room.
	later := read.Add(time.Minute)
	captureEvents(t, func() {
		b.onReceipt(context.Background(), receiptEvent(testRoom, testSelf, event.ReceiptTypeReadPrivate, later))
	})
	if got := b.room(testRoom).ReadUpTo; got != later.UnixMilli() {
		t.Errorf("readUpTo after a private receipt = %d, want %d", got, later.UnixMilli())
	}
}

// A receipt for something older -- a client catching up, a thread receipt --
// must not un-read what has been read since.
func TestReadPositionNeverMovesBackwards(t *testing.T) {
	b := testBridge()
	b.setReadUpTo(testRoom, 2000)

	if b.setReadUpTo(testRoom, 1000) {
		t.Error("an older receipt moved the read position back")
	}
	if got := b.room(testRoom).ReadUpTo; got != 2000 {
		t.Errorf("readUpTo = %d, want it held at 2000", got)
	}
	if b.setReadUpTo(testRoom, 0) {
		t.Error("a receipt with no timestamp was treated as a read position")
	}
}

// The read position has to survive a restart: a resumed sync is told what
// changed, and a receipt sent last week changed nothing since.
func TestReadPositionSurvivesARestart(t *testing.T) {
	t.Setenv("DMS_MATRIX_DIR", t.TempDir())

	b := testBridge()
	b.setReadUpTo(testRoom, 1700000000000)

	store, err := newRoomStore()
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	store.save(b.snapshotRooms())

	next := testBridge()
	next.rooms = store.load()
	if got := next.chatFor(testRoom).ReadUpTo; got != 1700000000000 {
		t.Errorf("readUpTo after a restart = %d, want it remembered", got)
	}
}

// What the catch-up sync reads out of a response: our own position, and
// nobody else's.
func TestOurReadReceiptIgnoresOtherPeople(t *testing.T) {
	mine := receiptEvent(testRoom, testSelf, event.ReceiptTypeRead, time.UnixMilli(5000))
	theirs := receiptEvent(testRoom, testAda, event.ReceiptTypeRead, time.UnixMilli(9000))

	if got := ourReadReceipt([]*event.Event{theirs}, testSelf); got != 0 {
		t.Errorf("read position from someone else's receipt = %d, want none", got)
	}
	if got := ourReadReceipt([]*event.Event{theirs, mine}, testSelf); got != 5000 {
		t.Errorf("read position = %d, want our own receipt's 5000", got)
	}
}

// Reading a conversation here has to tell the rest of the account, or it comes
// back unread on the phone that is sitting next to the machine it was read on.
//
// The host marks a conversation read at a moment in time and names no message,
// so the receipt goes to the newest event the room has shown us.
func TestReadReceiptNamesTheNewestEventSeen(t *testing.T) {
	b := testBridge()

	b.noteLastEvent(testRoom, id.EventID("$first"), 1000)
	b.noteLastEvent(testRoom, id.EventID("$second"), 2000)
	if got := b.receiptTarget(testRoom); got != id.EventID("$second") {
		t.Errorf("receipt target = %q, want the newest event", got)
	}

	// Backfill and a resumed sync both deliver older events; acknowledging one
	// would tell our other clients we have read less than we have.
	b.noteLastEvent(testRoom, id.EventID("$older"), 500)
	if got := b.receiptTarget(testRoom); got != id.EventID("$second") {
		t.Errorf("receipt target after an older event = %q, want the newest", got)
	}
}

// A room we have already acknowledged is not worth a request per reopening,
// and one this session has never seen has nothing to point at.
func TestNoReceiptWhenThereIsNothingToAcknowledge(t *testing.T) {
	b := testBridge()

	if got := b.receiptTarget(testRoom); got != "" {
		t.Errorf("receipt target for an unseen room = %q, want none", got)
	}

	b.noteLastEvent(testRoom, id.EventID("$evt"), 2000)
	b.setReadUpTo(testRoom, 3000)
	if got := b.receiptTarget(testRoom); got != "" {
		t.Errorf("receipt target for an already-read room = %q, want none", got)
	}
}

// The newest event survives a restart, so a conversation read straight after
// one is still acknowledged: a resumed sync is told what changed, and a room
// nobody has written in since changed nothing.
func TestNewestEventSurvivesARestart(t *testing.T) {
	t.Setenv("DMS_MATRIX_DIR", t.TempDir())

	b := testBridge()
	b.noteLastEvent(testRoom, id.EventID("$evt"), 1700000000000)

	store, err := newRoomStore()
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	store.save(b.snapshotRooms())

	next := testBridge()
	next.rooms = store.load()
	if got := next.receiptTarget(testRoom); got != id.EventID("$evt") {
		t.Errorf("receipt target after a restart = %q, want it remembered", got)
	}
}
