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
