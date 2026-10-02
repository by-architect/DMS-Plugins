package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
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

// A sync position belongs to the device that reached it. Resumed on a new
// device, the first sync reports only what changed since, so the new device's
// empty encryption store never learns which rooms are encrypted -- and sends
// into them in plain text.
func TestSyncPositionIsNotResumedOnAnotherDevice(t *testing.T) {
	t.Setenv("DMS_MATRIX_DIR", t.TempDir())
	ctx := context.Background()

	old, err := newSyncStore("OLDDEVICE")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	_ = old.SaveFilterID(ctx, "", "7")
	_ = old.SaveNextBatch(ctx, "", "s123_456")

	same, _ := newSyncStore("OLDDEVICE")
	if next, _ := same.LoadNextBatch(ctx, ""); next != "s123_456" {
		t.Errorf("the same device lost its position: %q", next)
	}

	other, _ := newSyncStore("NEWDEVICE")
	if next, _ := other.LoadNextBatch(ctx, ""); next != "" {
		t.Errorf("a new device resumed another's position %q, want an initial sync", next)
	}
	if filter, _ := other.LoadFilterID(ctx, ""); filter != "" {
		t.Errorf("a new device reused another's filter %q", filter)
	}
}

// A position written before positions were stamped names no device. It is
// taken as this one's, or every installation would redo an initial sync at once.
func TestUnstampedSyncPositionIsKept(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DMS_MATRIX_DIR", dir)

	legacy := []byte(`{"filterId":"7","nextBatch":"s123_456"}`)
	if err := os.WriteFile(filepath.Join(dir, "sync.json"), legacy, 0o600); err != nil {
		t.Fatal(err)
	}

	store, err := newSyncStore("DEVICE")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if next, _ := store.LoadNextBatch(context.Background(), ""); next != "s123_456" {
		t.Errorf("an unstamped position was dropped: %q", next)
	}
	if store.DeviceID != "DEVICE" {
		t.Errorf("device = %q, want the position stamped with this device", store.DeviceID)
	}
}

// Everything derived from a session goes when the session does, so the next
// sign-in starts from an initial sync rather than the old device's position.
func TestClearSessionRemovesWhatTheSessionLeftBehind(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DMS_MATRIX_DIR", dir)

	names := []string{"session.json", "crypto.db", "crypto.db-wal", "sync.json", "rooms.json"}
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	if err := clearSession(); err != nil {
		t.Fatalf("clearSession: %v", err)
	}
	for _, name := range names {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Errorf("%s survived signing out", name)
		}
	}

	// Nothing to remove is not a failure: signing out twice is still signed out.
	if err := clearSession(); err != nil {
		t.Errorf("clearSession on an empty directory: %v", err)
	}
}

// ---------------------------------------------------------------- the session's lifecycle

func hasState(frames []map[string]any, state string) bool {
	for _, f := range frames {
		if f["event"] == "state" && f["state"] == state {
			return true
		}
	}
	return false
}

func hasLoginForm(frames []map[string]any) bool {
	for _, f := range frames {
		if f["event"] == "auth" && f["method"] == "form" {
			fields, _ := f["fields"].([]any)
			return len(fields) == 3
		}
	}
	return false
}

func signedInBridge(t *testing.T) *bridge {
	t.Helper()
	b := testBridge()
	client, err := mautrix.NewClient("https://example.invalid", testSelf, "token")
	if err != nil {
		t.Fatal(err)
	}
	b.client = client
	return b
}

// A session the homeserver has ended is torn down, not merely forgotten on
// disk: the client left in place made the next Sign in report connected, and
// the needsLogin that went out carried no form to sign in with.
func TestEndedSessionAsksToSignInAgain(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DMS_MATRIX_DIR", dir)
	for _, name := range []string{"session.json", "sync.json"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	b := signedInBridge(t)
	frames := captureEvents(t, b.endSession)

	if b.getClient() != nil {
		t.Error("the client survived the end of its session")
	}
	if !hasState(frames, "needsLogin") || !hasLoginForm(frames) {
		t.Errorf("needsLogin went out without the form: %+v", frames)
	}
	if _, err := os.Stat(filepath.Join(dir, "session.json")); !os.IsNotExist(err) {
		t.Error("the session file survived")
	}

	// And Sign in, pressed now, asks for credentials rather than claiming a
	// connection.
	frames = captureEvents(t, func() { b.handleLogin(context.Background(), call{ID: 3}) })
	if hasState(frames, "connected") || !hasLoginForm(frames) {
		t.Errorf("sign in after the session ended: %+v", frames)
	}
}

// With a session running, Sign in has nothing to report: the sync loop says
// what state it is in, and "connected" here could be a lie.
func TestSignInDoesNotClaimConnected(t *testing.T) {
	b := signedInBridge(t)
	frames := captureEvents(t, func() { b.handleLogin(context.Background(), call{ID: 3}) })
	if hasState(frames, "connected") {
		t.Errorf("reported connected without a sync behind it: %+v", frames)
	}
}

// A second sign-in over a running session cleared the encryption store it had
// open and started a second sync loop beside the first.
func TestSecondSignInIsRefused(t *testing.T) {
	b := signedInBridge(t)
	params, _ := json.Marshal(map[string]any{"values": map[string]string{
		"homeserver": "https://example.invalid", "user": "@me:example.invalid", "password": "pw",
	}})

	frames := captureEvents(t, func() {
		b.handleAuthSubmit(context.Background(), call{ID: 9, Method: "authSubmit", Params: params})
	})
	if len(frames) != 1 || frames[0]["ok"] != false {
		t.Fatalf("a second sign-in was not refused: %+v", frames)
	}
	if errInfo, _ := frames[0]["error"].(map[string]any); errInfo["code"] != "already_signed_in" {
		t.Errorf("error = %v", frames[0]["error"])
	}
}

// A session file that cannot be read is the case where signing in again is
// the way out, so the form has to come with needsLogin.
func TestCorruptSessionOffersTheForm(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DMS_MATRIX_DIR", dir)
	if err := os.WriteFile(filepath.Join(dir, "session.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	b := testBridge()
	frames := captureEvents(t, b.connect)
	if !hasState(frames, "needsLogin") || !hasLoginForm(frames) {
		t.Errorf("a corrupt session gave no way to sign in: %+v", frames)
	}
}

// mautrix retries a failed sync by itself and never returns from the loop for
// it. Reported here, the host sees connecting during the outage and connected
// once it is over -- which is what makes it hold the backlog and judge it,
// rather than announcing it message by message.
func TestOutageIsReportedAndRecoveryToo(t *testing.T) {
	b := testBridge()
	syncer := &publishingSyncer{DefaultSyncer: mautrix.NewDefaultSyncer(), b: b}

	frames := captureEvents(t, func() {
		_, _ = syncer.OnFailedSync(nil, errors.New("network is unreachable"))
		_, _ = syncer.OnFailedSync(nil, errors.New("network is unreachable"))
	})
	count := 0
	for _, f := range frames {
		if f["event"] == "state" && f["state"] == "connecting" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("connecting reported %d times over one outage, want once", count)
	}

	frames = captureEvents(t, func() { b.afterSync(&mautrix.RespSync{}, "s123") })
	if !hasState(frames, "connected") {
		t.Errorf("recovery was not reported: %+v", frames)
	}

	// A revoked token is not an outage: runSync reports needsLogin for it.
	fresh := testBridge()
	revoked := &publishingSyncer{DefaultSyncer: mautrix.NewDefaultSyncer(), b: fresh}
	frames = captureEvents(t, func() {
		if _, err := revoked.OnFailedSync(nil, fmt.Errorf("sync: %w", mautrix.MUnknownToken)); err == nil {
			t.Error("a revoked token was retried")
		}
	})
	if hasState(frames, "connecting") {
		t.Errorf("a revoked token was reported as an outage: %+v", frames)
	}
}

// Only a request that never got an answer is waited out before encryption is
// set up; a homeserver that answered no will not change its mind.
func TestUnreachableIsOnlyNoAnswer(t *testing.T) {
	noAnswer := fmt.Errorf("initialise encryption: %w", mautrix.HTTPError{
		Message: "request error", WrappedError: errors.New("dial tcp: connection refused"),
	})
	if !isUnreachable(noAnswer) {
		t.Error("a refused connection was not counted as unreachable")
	}

	refused := mautrix.HTTPError{
		Response:  &http.Response{StatusCode: 401},
		RespError: &mautrix.RespError{ErrCode: "M_UNKNOWN_TOKEN"},
	}
	if isUnreachable(refused) {
		t.Error("an answer from the homeserver was counted as unreachable")
	}
	if isUnreachable(errors.New("mismatching identity key on server")) {
		t.Error("a broken store was counted as unreachable")
	}
}
