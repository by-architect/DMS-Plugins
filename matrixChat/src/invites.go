package main

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Invitations.
//
// An invitation is a room you are not in yet. The homeserver sends a handful of
// stripped state events -- who invited you, what the room is called -- and no
// timeline at all, which makes it the one kind of conversation that has nothing
// to say for itself.
//
// Three things follow from that, and this file is all three:
//
//   - It is published as an ordinary conversation tagged "invite", carrying an
//     activity line of its own. The host orders conversations by their last
//     activity and keeps the ones that have never had any out of the list, so
//     an invitation without a timestamp would be filed where nobody sees it.
//   - It is remembered on disk. A homeserver mentions an invitation in one sync
//     and never again, so anything not written down is gone on the next start.
//   - It can be answered: joining the room, or leaving it and forgetting it.

// noteMembership records what a sync response says about rooms we are not
// simply sitting in: invitations arriving, and invitations answered elsewhere.
//
// Returns the rooms whose standing changed, so the caller can publish and
// persist exactly those.
func (b *bridge) noteMembership(resp *mautrix.RespSync) []id.RoomID {
	var changed []id.RoomID

	for roomID, invited := range resp.Rooms.Invite {
		if b.noteInvite(roomID, inviterOf(invited, b.selfID())) {
			changed = append(changed, roomID)
		}
	}

	// Answered somewhere else: another client accepted it, or declined it, and
	// the room arrives here as an ordinary join or as a leave.
	for roomID := range resp.Rooms.Join {
		if _, moved := b.settleRoom(roomID, false); moved {
			changed = append(changed, roomID)
		}
	}
	for roomID := range resp.Rooms.Leave {
		wasInvited, moved := b.settleRoom(roomID, true)
		if wasInvited {
			// Declined on another device. The conversation it stood for was
			// never entered, so it is told to go rather than left sitting in
			// the list as an invitation that cannot be answered any more.
			emitEvent("chatGone", map[string]any{"chatId": string(roomID)})
		}
		if moved {
			changed = append(changed, roomID)
		}
	}
	return changed
}

// noteInvite records an invitation, reporting whether it is a new one.
func (b *bridge) noteInvite(roomID id.RoomID, inviter id.UserID) bool {
	b.mu.Lock()
	info := b.roomLocked(roomID)
	fresh := !info.Invited
	info.Invited = true
	info.Left = false
	if info.InviteTS == 0 {
		// The stripped state of an invitation carries no timestamps, so the
		// moment we heard about it is the best time there is.
		info.InviteTS = time.Now().UnixMilli()
	}
	if inviter != "" {
		info.InvitedBy = inviter
	}
	b.mu.Unlock()

	if fresh {
		// Sent with a count of one, once. An invitation nobody has answered is
		// something waiting, and it would otherwise arrive silently: its own
		// line is a system row, which deliberately never counts as unread or
		// raises a notification. Later republishes leave the count alone, so
		// opening it still clears the badge for good.
		waiting := 1
		chat := b.chatFor(roomID)
		chat.Unread = &waiting
		emitEvent("chat", map[string]any{"chat": chat})

		// A conversation with no messages in it reads as broken. This is the
		// invitation itself, as the one line of history it has.
		b.emitInviteMessage(roomID)
	}
	return fresh
}

// settleRoom clears an invitation once the room is joined or gone.
//
// Reports whether the room was still an unanswered invitation at that point --
// which is how an invitation answered on another device is recognised -- and
// whether anything changed at all.
func (b *bridge) settleRoom(roomID id.RoomID, left bool) (wasInvited, moved bool) {
	b.mu.Lock()
	defer b.mu.Unlock()

	info, known := b.rooms[roomID]
	if !known {
		if !left {
			return false, false
		}
		info = b.roomLocked(roomID)
	}

	wasInvited = info.Invited
	if !info.Invited && info.Left == left {
		return false, false
	}
	info.Invited = false
	info.Left = left
	return wasInvited, true
}

// inviterOf finds who sent the invitation.
//
// It is the sender of our own membership event: the stripped state names every
// member it bothers to include, and only that one is about us.
func inviterOf(invited *mautrix.SyncInvitedRoom, self id.UserID) id.UserID {
	if invited == nil || self == "" {
		return ""
	}

	for _, evt := range invited.State.Events {
		if evt == nil || evt.Type != event.StateMember || evt.GetStateKey() != string(self) {
			continue
		}
		if evt.Content.Parsed == nil {
			_ = evt.Content.ParseRaw(evt.Type)
		}
		content, ok := evt.Content.Parsed.(*event.MemberEventContent)
		if !ok || content.Membership != event.MembershipInvite {
			continue
		}
		return evt.Sender
	}
	return ""
}

// emitInviteMessage gives the invitation a timeline entry.
//
// A system kind on purpose: nobody wrote it, so it must not count as unread,
// raise a notification, or make this look like a conversation we take part in.
// The id is derived from the room, so a restart re-states the same row instead
// of stacking another copy of it.
func (b *bridge) emitInviteMessage(roomID id.RoomID) {
	b.mu.RLock()
	info := b.rooms[roomID]
	var inviter id.UserID
	var ts int64
	if info != nil {
		inviter = info.InvitedBy
		ts = info.InviteTS
	}
	b.mu.RUnlock()

	if ts == 0 {
		ts = time.Now().UnixMilli()
	}

	msg := messageObj{
		ID:     inviteMessageID(roomID),
		ChatID: string(roomID),
		TS:     ts,
		Kind:   "system",
		Text:   b.inviteLine(roomID),
	}
	if inviter != "" {
		msg.SenderID = string(inviter)
		msg.SenderName = b.senderName(roomID, inviter)
	}
	emitEvent("message", map[string]any{"message": msg})
}

func inviteMessageID(roomID id.RoomID) string {
	return string(roomID) + "/invite"
}

// inviteLine is what the invitation says in the conversation list.
func (b *bridge) inviteLine(roomID id.RoomID) string {
	b.mu.RLock()
	info := b.rooms[roomID]
	b.mu.RUnlock()

	if info == nil || info.InvitedBy == "" {
		return "You have been invited to this room"
	}
	return b.senderName(roomID, info.InvitedBy) + " invited you to this room"
}

// pendingInvites lists the rooms we have been invited to and not answered.
//
// Joined rooms are passed in rather than looked up: an invitation accepted on
// another device is a joined room here, and publishing it twice -- once as a
// room and once as an invitation -- would put the tag back on it.
func (b *bridge) pendingInvites(joined []id.RoomID) []id.RoomID {
	isJoined := make(map[id.RoomID]bool, len(joined))
	for _, roomID := range joined {
		isJoined[roomID] = true
	}

	b.mu.RLock()
	defer b.mu.RUnlock()

	var pending []id.RoomID
	for roomID, info := range b.rooms {
		if info.Invited && !info.Left && !isJoined[roomID] {
			pending = append(pending, roomID)
		}
	}
	return pending
}

// hasLeft reports whether we are out of this room, and so whether it has
// stopped being a conversation worth publishing.
func (b *bridge) hasLeft(roomID id.RoomID) bool {
	b.mu.RLock()
	defer b.mu.RUnlock()

	info, ok := b.rooms[roomID]
	return ok && info.Left
}

// ---------------------------------------------------------------- answering

// handleAcceptInvite joins the room.
func (b *bridge) handleAcceptInvite(ctx context.Context, c call) {
	roomID, client, okToGo := b.inviteTarget(c)
	if !okToGo {
		return
	}

	if _, err := client.JoinRoomByID(ctx, roomID); err != nil {
		fail(c.ID, "join_failed", "%s", serverMessage(err, "could not join the room"))
		return
	}

	b.mu.Lock()
	info := b.roomLocked(roomID)
	info.Invited = false
	info.Left = false
	b.mu.Unlock()

	ok(c.ID, nil)
	logf("info", "joined %s", roomID)

	// Republished at once so the invitation tag comes off now rather than
	// whenever the next sync happens to mention the room.
	b.publishSome([]id.RoomID{roomID})
	go b.persistRooms()
}

// handleDeclineInvite leaves the room and forgets it.
//
// Forgetting as well as leaving is what makes a declined invitation stay gone:
// a room merely left is still one the homeserver will hand back with our old
// membership in it.
func (b *bridge) handleDeclineInvite(ctx context.Context, c call) {
	roomID, client, okToGo := b.inviteTarget(c)
	if !okToGo {
		return
	}

	if _, err := client.LeaveRoom(ctx, roomID); err != nil {
		fail(c.ID, "leave_failed", "%s", serverMessage(err, "could not decline the invitation"))
		return
	}
	if _, err := client.ForgetRoom(ctx, roomID); err != nil {
		// Declined either way: forgetting only stops it reappearing in a full
		// state sync, so this is not worth failing the call over.
		logf("debug", "could not forget %s: %v", roomID, err)
	}

	b.mu.Lock()
	info := b.roomLocked(roomID)
	info.Invited = false
	info.Left = true
	b.mu.Unlock()

	ok(c.ID, nil)
	logf("info", "declined the invitation to %s", roomID)
	go b.persistRooms()
}

// inviteTarget reads the room an invitation call is about, answering the call
// itself when there is nothing to act on.
func (b *bridge) inviteTarget(c call) (id.RoomID, *mautrix.Client, bool) {
	var params struct {
		ChatID string `json:"chatId"`
	}
	_ = json.Unmarshal(c.Params, &params)

	if params.ChatID == "" {
		fail(c.ID, "bad_params", "chatId is required")
		return "", nil, false
	}

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return "", nil, false
	}
	return id.RoomID(params.ChatID), client, true
}

// serverMessage prefers the homeserver's own words, which are the ones worth
// showing: "You are not invited to this room" rather than "join_failed". This
// string is what the user is shown.
func serverMessage(err error, fallback string) string {
	if err == nil {
		return fallback
	}

	var httpErr mautrix.HTTPError
	if errors.As(err, &httpErr) && httpErr.RespError != nil && httpErr.RespError.Err != "" {
		return httpErr.RespError.Err
	}
	return fallback + ": " + err.Error()
}

// applyStrippedState feeds an invitation's state through the ordinary handlers.
//
// The sync loop gets this for free -- mautrix dispatches invite state like any
// other -- but the catch-up sync bypasses the syncer, so it has to do it itself
// or every invitation it finds would be named after its room id.
func (b *bridge) applyStrippedState(roomID id.RoomID, events []*event.Event) {
	ctx := context.Background()

	for _, evt := range events {
		if evt == nil {
			continue
		}
		if evt.Content.Parsed == nil {
			_ = evt.Content.ParseRaw(evt.Type)
		}
		evt.RoomID = roomID

		switch evt.Type {
		case event.StateCreate:
			b.onCreate(ctx, evt)
		case event.StateRoomName:
			b.onRoomName(ctx, evt)
		case event.StateCanonicalAlias:
			b.onCanonicalAlias(ctx, evt)
		case event.StateTopic:
			b.onTopic(ctx, evt)
		case event.StateEncryption:
			b.onEncryption(ctx, evt)
		case event.StateRoomAvatar:
			b.onRoomAvatar(ctx, evt)
		case event.StateMember:
			b.onMember(ctx, evt)
		}
	}
}
