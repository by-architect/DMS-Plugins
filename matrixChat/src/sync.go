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

	// The initial sync carries every room's state at once. Publishing chats
	// during it would name each room after its id, because the member events
	// that name it may not have been processed yet.
	syncer.OnSync(b.onSyncResponse)
}

// onSyncResponse publishes the room list once the cache is populated.
func (b *bridge) onSyncResponse(ctx context.Context, resp *mautrix.RespSync, since string) bool {
	first := since == ""

	b.mu.Lock()
	wasFirst := !b.firstSyncDone
	b.firstSyncDone = true
	b.mu.Unlock()

	if first || wasFirst {
		emitState("connected")
		go b.publishRooms()
		return true
	}

	// An incremental sync: refresh only the rooms it mentioned, so a busy
	// account does not republish thousands of rooms on every round trip.
	touched := make([]id.RoomID, 0, len(resp.Rooms.Join)+len(resp.Rooms.Invite))
	for roomID := range resp.Rooms.Join {
		touched = append(touched, roomID)
	}
	for roomID := range resp.Rooms.Invite {
		b.room(roomID).Invited = true
		touched = append(touched, roomID)
	}
	if len(touched) > 0 {
		go b.publishSome(touched)
	}
	return true
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

	chats := make([]chatObj, 0, len(joined.JoinedRooms))
	for _, roomID := range joined.JoinedRooms {
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
}

func (b *bridge) publishSome(roomIDs []id.RoomID) {
	seen := map[id.RoomID]bool{}
	chats := make([]chatObj, 0, len(roomIDs))

	for _, roomID := range roomIDs {
		if seen[roomID] {
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

	if !ready {
		return
	}
	emitEvent("chat", map[string]any{"chat": b.chatFor(roomID)})
}
