package main

import (
	"context"
	"strings"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// registerHandlers wires every event type this bridge cares about.
//
// Matrix delivers a room's identity as a stream of state events rather than as
// a record, so most of these exist only to keep the room cache current.
func (b *bridge) registerHandlers(syncer *mautrix.DefaultSyncer) {
	// --- room identity
	syncer.OnEventType(event.StateRoomName, b.onRoomName)
	syncer.OnEventType(event.StateCanonicalAlias, b.onCanonicalAlias)
	syncer.OnEventType(event.StateTopic, b.onTopic)
	syncer.OnEventType(event.StateMember, b.onMember)
	syncer.OnEventType(event.StateEncryption, b.onEncryption)
	syncer.OnEventType(event.StateCreate, b.onCreate)
	syncer.OnEventType(event.StateRoomAvatar, b.onRoomAvatar)

	// --- account data
	syncer.OnEventType(event.AccountDataDirectChats, b.onDirectChats)
	syncer.OnEventType(event.AccountDataRoomTags, b.onRoomTags)

	// --- the conversation itself
	syncer.OnEventType(event.EventMessage, b.onMessage)
	syncer.OnEventType(event.EventSticker, b.onMessage)
	syncer.OnEventType(event.EventRedaction, b.onRedaction)
	syncer.OnEventType(event.EphemeralEventReceipt, b.onReceipt)

	// Deliberately not syncer.OnSync: mautrix runs those listeners before it
	// dispatches the response's events, so a callback there sees an empty room
	// cache and names every room after its id. See publishingSyncer.
}

// publishingSyncer publishes rooms once the response has actually been applied.
//
// mautrix's ProcessResponse calls its sync listeners first and dispatches the
// room events afterwards. Wrapping it is the only hook that runs after the
// m.room.name and m.room.member events have reached the cache, which is what a
// room needs before it can be given a name.
type publishingSyncer struct {
	*mautrix.DefaultSyncer

	b *bridge
}

func (s *publishingSyncer) ProcessResponse(ctx context.Context, resp *mautrix.RespSync, since string) error {
	if err := s.DefaultSyncer.ProcessResponse(ctx, resp, since); err != nil {
		return err
	}
	s.b.afterSync(resp, since)
	return nil
}

// afterSync publishes the room list once the cache is populated.
func (b *bridge) afterSync(resp *mautrix.RespSync, since string) {
	first := since == ""

	b.mu.Lock()
	wasFirst := !b.firstSyncDone
	b.firstSyncDone = true
	b.mu.Unlock()

	// Membership first, and on every sync rather than only incremental ones:
	// an invitation is mentioned once and never again, so a response skipped
	// here is an invitation nobody ever sees.
	changed := b.noteMembership(resp)

	if first || wasFirst {
		emitState("connected")
		go b.publishRooms()
		return
	}

	// An incremental sync: refresh only the rooms it mentioned, so a busy
	// account does not republish thousands of rooms on every round trip.
	touched := make([]id.RoomID, 0, len(resp.Rooms.Join)+len(changed))
	for roomID := range resp.Rooms.Join {
		touched = append(touched, roomID)
	}
	touched = append(touched, changed...)

	if len(touched) > 0 {
		go b.publishSome(touched)
	}
	if len(changed) > 0 {
		// Written now rather than at shutdown: an invitation that only exists
		// in memory is lost if the shell is killed rather than stopped.
		go b.persistRooms()
	}
}

// publishRooms sends the whole room list.
//
// Without this a room only becomes searchable once someone writes in it, so a
// freshly linked account would appear almost empty.
func (b *bridge) publishRooms() {
	client := b.getClient()
	if client == nil {
		return
	}

	joined, err := client.JoinedRooms(context.Background())
	if err != nil {
		logf("warn", "could not list joined rooms: %v", err)
		return
	}

	// Anything the cache cannot name is looked up before publishing, so a room
	// is never sent to the host as a raw id. Only joined rooms: the state of a
	// room we have merely been invited to is not ours to read.
	b.hydrate(context.Background(), client, joined.JoinedRooms)

	// Invitations are not in the joined list, and after the sync that carried
	// one the homeserver never mentions it again -- so they come from the
	// cache, which is the only thing that still remembers them.
	rooms := make([]id.RoomID, 0, len(joined.JoinedRooms))
	rooms = append(rooms, joined.JoinedRooms...)
	rooms = append(rooms, b.pendingInvites(joined.JoinedRooms)...)

	chats := make([]chatObj, 0, len(rooms))
	for _, roomID := range rooms {
		chats = append(chats, b.chatFor(roomID))
	}

	// Batched: the host writes a batch in one transaction, and an account in
	// hundreds of rooms would otherwise arrive as one enormous frame.
	const batchSize = 200
	for start := 0; start < len(chats); start += batchSize {
		end := start + batchSize
		if end > len(chats) {
			end = len(chats)
		}
		emitEvent("chats", map[string]any{"chats": chats[start:end]})
	}

	if len(chats) > 0 {
		logf("info", "published %d rooms", len(chats))
	}
	b.persistRooms()
}

func (b *bridge) publishSome(roomIDs []id.RoomID) {
	seen := map[id.RoomID]bool{}
	chats := make([]chatObj, 0, len(roomIDs))

	for _, roomID := range roomIDs {
		if seen[roomID] || b.hasLeft(roomID) {
			continue
		}
		seen[roomID] = true
		chats = append(chats, b.chatFor(roomID))
	}
	if len(chats) > 0 {
		emitEvent("chats", map[string]any{"chats": chats})
	}
}

// chatFor assembles the contract's view of a room.
func (b *bridge) chatFor(roomID id.RoomID) chatObj {
	b.mu.RLock()
	info := b.rooms[roomID]
	b.mu.RUnlock()

	chat := chatObj{
		ID:      string(roomID),
		Name:    b.displayName(roomID),
		Handles: b.handlesFor(roomID),
		Tags:    b.tagsFor(roomID),
	}
	if info != nil {
		// A room is a group unless Matrix has been told it is a direct chat.
		chat.IsGroup = !info.IsDirect
		chat.Subject = info.Topic

		// An invitation has no timeline, so it has to carry its own activity
		// line: the host hides conversations that have never had any, which is
		// exactly what an unanswered invitation looks like without this.
		if info.Invited {
			chat.LastTS = info.InviteTS
			chat.LastText = b.inviteLine(roomID)
		}
	}
	return chat
}

// ---------------------------------------------------------------- state

func (b *bridge) onRoomName(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.RoomNameEventContent)
	if !ok {
		return
	}
	b.room(evt.RoomID).Name = content.Name
	b.touchRoom(evt.RoomID)
}

func (b *bridge) onCanonicalAlias(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.CanonicalAliasEventContent)
	if !ok {
		return
	}
	b.room(evt.RoomID).Alias = string(content.Alias)
	b.touchRoom(evt.RoomID)
}

func (b *bridge) onTopic(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.TopicEventContent)
	if !ok {
		return
	}
	b.room(evt.RoomID).Topic = content.Topic
}

// onMember tracks who is in a room and what they are called there.
//
// Display names are per-room in Matrix, which is why they are stored per room
// rather than once per user.
func (b *bridge) onMember(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.MemberEventContent)
	if !ok {
		return
	}

	user := id.UserID(evt.GetStateKey())
	if user == "" {
		return
	}

	b.mu.Lock()
	info := b.roomLocked(evt.RoomID)
	switch content.Membership {
	case event.MembershipJoin, event.MembershipInvite:
		name := strings.TrimSpace(content.Displayname)
		if name == "" {
			name = string(user)
		}
		info.Members[user] = name
	default:
		// Left, banned or knocked: they no longer name the room.
		delete(info.Members, user)
	}

	// Our own membership is not just another member: it decides whether this
	// is a conversation at all. An invitation accepted or a room left anywhere
	// else in the world arrives here as one of these.
	if user == b.selfIDLocked() {
		switch content.Membership {
		case event.MembershipJoin:
			info.Invited = false
			info.Left = false
		case event.MembershipLeave, event.MembershipBan:
			// Left only, deliberately: whether this room was an invitation up
			// to this moment is what tells noteMembership that an invitation
			// was turned down elsewhere, and clearing it here would erase that.
			info.Left = true
		}
	}
	b.mu.Unlock()

	b.touchRoom(evt.RoomID)
}

func (b *bridge) onEncryption(ctx context.Context, evt *event.Event) {
	b.room(evt.RoomID).Encrypted = true
	b.touchRoom(evt.RoomID)
}

func (b *bridge) onCreate(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.CreateEventContent)
	if !ok {
		return
	}
	// A space is a container for other rooms, not a conversation.
	b.room(evt.RoomID).IsSpace = content.Type == event.RoomTypeSpace
	b.touchRoom(evt.RoomID)
}

func (b *bridge) onRoomAvatar(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.RoomAvatarEventContent)
	if !ok {
		return
	}
	b.room(evt.RoomID).AvatarURL = content.URL.ParseOrIgnore()
}

// onDirectChats is how Matrix records which rooms are one-to-one.
//
// There is no flag on the room itself: it is a map in the user's account data,
// which is why a direct chat cannot be recognised from the room alone.
func (b *bridge) onDirectChats(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.DirectChatsEventContent)
	if !ok {
		return
	}

	var touched []id.RoomID
	b.mu.Lock()
	for _, roomIDs := range *content {
		for _, roomID := range roomIDs {
			b.roomLocked(roomID).IsDirect = true
			touched = append(touched, roomID)
		}
	}
	b.mu.Unlock()

	if len(touched) > 0 {
		go b.publishSome(touched)
	}
}

func (b *bridge) onRoomTags(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*event.TagEventContent)
	if !ok {
		return
	}

	tags := make([]string, 0, len(content.Tags))
	for tag := range content.Tags {
		tags = append(tags, string(tag))
	}

	b.room(evt.RoomID).Tags = tags
	b.touchRoom(evt.RoomID)
}

// touchRoom republishes a room whose identity changed, but only once the first
// sync is done -- during it, every room changes many times.
func (b *bridge) touchRoom(roomID id.RoomID) {
	b.mu.RLock()
	ready := b.firstSyncDone
	b.mu.RUnlock()

	if !ready || b.hasLeft(roomID) {
		return
	}
	emitEvent("chat", map[string]any{"chat": b.chatFor(roomID)})
}
