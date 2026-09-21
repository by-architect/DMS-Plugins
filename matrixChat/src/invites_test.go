package main

import (
	"strings"
	"testing"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// inviteState is the stripped state a homeserver sends with an invitation:
// enough to say what the room is and who asked, and nothing else.
func inviteState(inviter id.UserID, roomName string) *mautrix.SyncInvitedRoom {
	mine := &event.Event{Type: event.StateMember, Sender: inviter}
	self := string(testSelf)
	mine.StateKey = &self
	mine.Content.Parsed = &event.MemberEventContent{Membership: event.MembershipInvite}

	theirs := &event.Event{Type: event.StateMember, Sender: inviter}
	them := string(inviter)
	theirs.StateKey = &them
	theirs.Content.Parsed = &event.MemberEventContent{Membership: event.MembershipJoin, Displayname: "Ada"}

	named := &event.Event{Type: event.StateRoomName, Sender: inviter}
	empty := ""
	named.StateKey = &empty
	named.Content.Parsed = &event.RoomNameEventContent{Name: roomName}

	return &mautrix.SyncInvitedRoom{State: mautrix.SyncEventsList{
		Events: []*event.Event{named, theirs, mine},
	}}
}

func inviteSync(inviter id.UserID, roomName string) *mautrix.RespSync {
	return &mautrix.RespSync{Rooms: mautrix.RespSyncRooms{
		Invite: map[id.RoomID]*mautrix.SyncInvitedRoom{testRoom: inviteState(inviter, roomName)},
	}}
}

// An invitation has no timeline, and the host hides conversations that have
// never had any activity. Without an activity line of its own it is stored and
// then never seen, which is exactly how this started.
func TestInviteIsPublishedWithActivity(t *testing.T) {
	b := testBridge()
	resp := inviteSync(testAda, "Study Group")
	b.applyStrippedState(testRoom, resp.Rooms.Invite[testRoom].State.Events)

	frames := captureEvents(t, func() {
		b.publishSome(b.noteMembership(resp))
	})

	var chat map[string]any
	var message map[string]any
	var announced map[string]any
	for _, f := range frames {
		switch f["event"] {
		case "chats":
			list, _ := f["chats"].([]any)
			if len(list) > 0 {
				chat, _ = list[0].(map[string]any)
			}
		case "chat":
			announced, _ = f["chat"].(map[string]any)
		case "message":
			message, _ = f["message"].(map[string]any)
		}
	}

	// Its own line is a system row, which never counts as unread, so the
	// invitation has to say once that something is waiting or it arrives with
	// no sign at all.
	if announced == nil {
		t.Fatalf("the invitation was not announced on arrival: %+v", frames)
	}
	if unread, _ := announced["unread"].(float64); unread != 1 {
		t.Errorf("unread = %v, want 1 on a new invitation", announced["unread"])
	}

	if chat == nil {
		t.Fatalf("the invitation was not published as a chat: %+v", frames)
	}
	if chat["name"] != "Study Group" {
		t.Errorf("name = %v, want the invited room's name", chat["name"])
	}
	if ts, _ := chat["lastTs"].(float64); ts <= 0 {
		t.Errorf("lastTs = %v, want the moment the invitation was seen", chat["lastTs"])
	}
	if text, _ := chat["lastText"].(string); !strings.Contains(text, "Ada") {
		t.Errorf("lastText = %q, want it to say who invited us", text)
	}

	tags, _ := chat["tags"].([]any)
	if !containsTag(tags, "invite") {
		t.Errorf("tags = %v, want the invite tag", tags)
	}

	// The conversation view reads empty without it, and a system kind is what
	// keeps it out of unread counts and notifications.
	if message == nil {
		t.Fatal("the invitation produced no message to show in the conversation")
	}
	if message["kind"] != "system" {
		t.Errorf("kind = %v, want system", message["kind"])
	}
	if message["fromMe"] == true {
		t.Error("the invitation was attributed to us")
	}
}

// The same invitation seen twice is one invitation. Restarts re-read it from
// the cache, so a second message would stack up a copy on every start.
func TestInviteIsOnlyAnnouncedOnce(t *testing.T) {
	b := testBridge()
	resp := inviteSync(testAda, "Study Group")

	if changed := b.noteMembership(resp); len(changed) != 1 {
		t.Fatalf("first sighting changed %d rooms, want 1", len(changed))
	}
	frames := captureEvents(t, func() {
		if changed := b.noteMembership(resp); len(changed) != 0 {
			t.Errorf("the same invitation was reported as new again: %v", changed)
		}
	})
	for _, f := range frames {
		if f["event"] == "message" {
			t.Errorf("the invitation was announced twice: %+v", f)
		}
	}
}

// Joining is what ends an invitation, wherever it was accepted. The tag has to
// come off with it, which is why the tag list is sent even when it is empty.
func TestJoiningEndsTheInvitation(t *testing.T) {
	b := testBridge()
	b.noteMembership(inviteSync(testAda, "Study Group"))

	joined := &mautrix.RespSync{Rooms: mautrix.RespSyncRooms{
		Join: map[id.RoomID]*mautrix.SyncJoinedRoom{testRoom: {}},
	}}
	if changed := b.noteMembership(joined); len(changed) != 1 {
		t.Fatalf("the join changed %d rooms, want 1", len(changed))
	}

	chat := b.chatFor(testRoom)
	if containsString(chat.Tags, "invite") {
		t.Errorf("tags = %v, still an invitation after joining", chat.Tags)
	}
	if chat.Tags == nil {
		t.Error("tags = nil, which tells the host to keep the invite tag it already has")
	}
	if chat.LastText != "" {
		t.Errorf("lastText = %q, want the room's own activity line back", chat.LastText)
	}
}

// A declined invitation must stay gone. The leave it causes comes back around
// through sync, and republishing on that would put the room back in the list.
func TestDeclinedRoomIsNotPublished(t *testing.T) {
	b := testBridge()
	b.noteMembership(inviteSync(testAda, "Study Group"))

	left := &mautrix.RespSync{Rooms: mautrix.RespSyncRooms{
		Leave: map[id.RoomID]*mautrix.SyncLeftRoom{testRoom: {}},
	}}
	b.noteMembership(left)

	if !b.hasLeft(testRoom) {
		t.Fatal("the room is still counted as one we are in")
	}
	if pending := b.pendingInvites(nil); len(pending) != 0 {
		t.Errorf("pending invitations = %v, want none", pending)
	}

	frames := captureEvents(t, func() {
		b.publishSome([]id.RoomID{testRoom})
	})
	if len(frames) != 0 {
		t.Errorf("a room we left was published anyway: %+v", frames)
	}
}

// An invitation is mentioned in one sync and never again, so the cache is the
// only thing that still knows about it on the next start.
func TestPendingInviteSurvivesARestart(t *testing.T) {
	t.Setenv("DMS_MATRIX_DIR", t.TempDir())

	b := testBridge()
	b.noteMembership(inviteSync(testAda, "Study Group"))

	store, err := newRoomStore()
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	store.save(b.snapshotRooms())

	next := testBridge()
	next.rooms = store.load()

	pending := next.pendingInvites(nil)
	if len(pending) != 1 || pending[0] != testRoom {
		t.Fatalf("pending invitations after a restart = %v, want the invited room", pending)
	}
	info := next.rooms[testRoom]
	if info.InviteTS == 0 || info.InvitedBy != testAda {
		t.Errorf("invitation detail lost: ts=%d by=%q", info.InviteTS, info.InvitedBy)
	}
}

// A room we have already joined is not an invitation, even if the cache still
// carries one -- otherwise accepting elsewhere would republish the tag.
func TestJoinedRoomsAreNotPendingInvites(t *testing.T) {
	b := testBridge()
	b.noteMembership(inviteSync(testAda, "Study Group"))

	if pending := b.pendingInvites([]id.RoomID{testRoom}); len(pending) != 0 {
		t.Errorf("pending invitations = %v, want none for a joined room", pending)
	}
}

func TestInviterOfIsTheSenderOfOurOwnMembership(t *testing.T) {
	if got := inviterOf(inviteState(testAda, "Study Group"), testSelf); got != testAda {
		t.Errorf("inviter = %q, want %q", got, testAda)
	}
	if got := inviterOf(nil, testSelf); got != "" {
		t.Errorf("inviter of nothing = %q, want empty", got)
	}
}

func containsTag(tags []any, want string) bool {
	for _, tag := range tags {
		if s, _ := tag.(string); s == want {
			return true
		}
	}
	return false
}

func containsString(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}

// Declining on another device has to reach the host, which otherwise keeps a
// row for an invitation that can no longer be answered.
func TestInvitationDeclinedElsewhereIsWithdrawn(t *testing.T) {
	b := testBridge()
	b.noteMembership(inviteSync(testAda, "Study Group"))

	left := &mautrix.RespSync{Rooms: mautrix.RespSyncRooms{
		Leave: map[id.RoomID]*mautrix.SyncLeftRoom{testRoom: {}},
	}}

	frames := captureEvents(t, func() { b.noteMembership(left) })
	if !hasFrame(frames, "chatGone", string(testRoom)) {
		t.Errorf("the withdrawn invitation was not reported: %+v", frames)
	}

	// The same leave arriving again is not a second withdrawal.
	frames = captureEvents(t, func() { b.noteMembership(left) })
	if hasFrame(frames, "chatGone", string(testRoom)) {
		t.Errorf("the withdrawal was repeated: %+v", frames)
	}
}

// Leaving a room we were actually in is not the same thing: that conversation
// happened, and its history is not the provider's to delete.
func TestLeavingAJoinedRoomIsNotAWithdrawal(t *testing.T) {
	b := testBridge()
	b.settleRoom(testRoom, false)

	left := &mautrix.RespSync{Rooms: mautrix.RespSyncRooms{
		Leave: map[id.RoomID]*mautrix.SyncLeftRoom{testRoom: {}},
	}}
	frames := captureEvents(t, func() { b.noteMembership(left) })
	if hasFrame(frames, "chatGone", string(testRoom)) {
		t.Errorf("leaving a joined room asked for its history to be removed: %+v", frames)
	}
}

func hasFrame(frames []map[string]any, event, chatID string) bool {
	for _, f := range frames {
		if f["event"] == event && f["chatId"] == chatID {
			return true
		}
	}
	return false
}
