package main

import (
	"os"
	"testing"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// The room cache must survive a restart.
//
// A homeserver only sends full room state on a first sync. Every later run
// resumes from a stored position and sees none, so a cache that did not persist
// would come back empty and name every room after its id -- which is exactly
// what happened against a real account.
func TestRoomCacheRoundTrip(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DMS_MATRIX_DIR", dir)

	store, err := newRoomStore()
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	info := newRoomInfo()
	info.Name = "The Room"
	info.Alias = "#room:example.org"
	info.IsDirect = true
	info.Encrypted = true
	info.Members[testAda] = "Ada"

	store.save(map[id.RoomID]*roomInfo{testRoom: info})

	loaded := store.load()
	got, ok := loaded[testRoom]
	if !ok {
		t.Fatal("the room did not survive the round trip")
	}
	if got.Name != "The Room" || got.Alias != "#room:example.org" {
		t.Errorf("identity lost: %+v", got)
	}
	if !got.IsDirect || !got.Encrypted {
		t.Errorf("flags lost: direct=%v encrypted=%v", got.IsDirect, got.Encrypted)
	}
	if got.Members[testAda] != "Ada" {
		t.Errorf("members lost: %+v", got.Members)
	}
}

// A room of four hundred people has a name of its own, so storing its whole
// membership would be megabytes of disk for nothing.
func TestLargeRoomMembersAreNotStored(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DMS_MATRIX_DIR", dir)

	store, _ := newRoomStore()

	big := newRoomInfo()
	big.Name = "Big Room"
	for i := 0; i < maxStoredMembers+1; i++ {
		big.Members[id.UserID(string(rune('a'+i%26))+string(rune('0'+i/26))+":example.org")] = "Someone"
	}

	store.save(map[id.RoomID]*roomInfo{testRoom: big})

	got := store.load()[testRoom]
	if len(got.Members) != 0 {
		t.Errorf("stored %d members for a large room, want none", len(got.Members))
	}
	if got.Name != "Big Room" {
		t.Error("the name must still be kept")
	}
}

func TestMissingCacheIsNotAnError(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DMS_MATRIX_DIR", dir)

	store, err := newRoomStore()
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if rooms := store.load(); len(rooms) != 0 {
		t.Errorf("expected an empty cache, got %d rooms", len(rooms))
	}
}

func TestCorruptCacheIsIgnored(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DMS_MATRIX_DIR", dir)

	store, _ := newRoomStore()
	if err := os.WriteFile(store.path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	// Rebuilt from the server rather than crashing the bridge.
	if rooms := store.load(); len(rooms) != 0 {
		t.Errorf("a corrupt cache should load as empty, got %d", len(rooms))
	}
}

// Only rooms that would otherwise show as a raw id are worth a request.
func TestNeedsHydration(t *testing.T) {
	b := testBridge()

	if !b.needsHydration(id.RoomID("!unknown:example.org")) {
		t.Error("a room we have never seen must be fetched")
	}

	named := b.room(testRoom)
	named.Name = "Known"
	if b.needsHydration(testRoom) {
		t.Error("a room with a name must not be fetched")
	}

	other := id.RoomID("!members:example.org")
	b.room(other).Members[testAda] = "Ada"
	if b.needsHydration(other) {
		t.Error("a room nameable from its members must not be fetched")
	}

	empty := id.RoomID("!empty:example.org")
	b.room(empty)
	if !b.needsHydration(empty) {
		t.Error("a room with nothing to name it must be fetched")
	}
}

// Fetched state arrives already parsed. Re-parsing it and skipping on error
// silently discarded every event, which left all 75 rooms named by id.
func TestApplyStateUsesAlreadyParsedContent(t *testing.T) {
	b := testBridge()

	nameEvt := &event.Event{Type: event.StateRoomName}
	nameEvt.Content.Parsed = &event.RoomNameEventContent{Name: "Fetched Name"}

	stateKey := string(testAda)
	memberEvt := &event.Event{Type: event.StateMember, StateKey: &stateKey}
	memberEvt.Content.Parsed = &event.MemberEventContent{
		Membership:  event.MembershipJoin,
		Displayname: "Ada",
	}

	b.applyState(testRoom, mautrix.RoomStateMap{
		event.StateRoomName: {"": nameEvt},
		event.StateMember:   {stateKey: memberEvt},
	})

	if got := b.displayName(testRoom); got != "Fetched Name" {
		t.Errorf("display name = %q, want the fetched name", got)
	}
	if got := b.senderName(testRoom, testAda); got != "Ada" {
		t.Errorf("sender name = %q, want Ada", got)
	}
}
