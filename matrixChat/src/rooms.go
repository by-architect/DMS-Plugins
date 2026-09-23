package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Remembering what rooms are called, between runs.
//
// A room's identity arrives as state events, and a homeserver only sends the
// full state on the very first sync. Every run afterwards resumes from a stored
// next_batch and sees no state at all, so a cache held only in memory comes back
// empty and names every room after its id.
//
// Two things fix that: the cache is written to disk, and any room that is still
// nameless after loading is fetched once from the server.

// maxStoredMembers caps how many members are kept per room.
//
// Members are only needed to name a room that has no name of its own -- a direct
// message, or a small unnamed group. A room of four hundred people has a name,
// so storing its entire membership would be megabytes of disk for nothing.
const maxStoredMembers = 32

type persistedRoom struct {
	Name      string `json:"name,omitempty"`
	Alias     string `json:"alias,omitempty"`
	Topic     string `json:"topic,omitempty"`
	IsDirect  bool   `json:"isDirect,omitempty"`
	IsSpace   bool   `json:"isSpace,omitempty"`
	Encrypted bool   `json:"encrypted,omitempty"`

	// An unanswered invitation has to survive a restart for the same reason a
	// name does, and more urgently: the homeserver mentions it in one sync and
	// never again, so a cache that forgot it would leave the invitation
	// invisible until somebody answered it elsewhere.
	Invited   bool   `json:"invited,omitempty"`
	Left      bool   `json:"left,omitempty"`
	InviteTS  int64  `json:"inviteTs,omitempty"`
	InvitedBy string `json:"invitedBy,omitempty"`
	ReadUpTo  int64  `json:"readUpTo,omitempty"`

	// The newest event seen, so a room read here right after a restart can
	// still be acknowledged upstream: the resumed sync is told what changed,
	// and a room nobody has written in since changed nothing.
	LastEventID string `json:"lastEventId,omitempty"`
	LastEventTS int64  `json:"lastEventTs,omitempty"`

	Tags    []string          `json:"tags,omitempty"`
	Members map[string]string `json:"members,omitempty"`
}

type roomStore struct {
	mu   sync.Mutex
	path string
}

func newRoomStore() (*roomStore, error) {
	dir, err := stateDir()
	if err != nil {
		return nil, err
	}
	return &roomStore{path: filepath.Join(dir, "rooms.json")}, nil
}

func (s *roomStore) load() map[id.RoomID]*roomInfo {
	rooms := map[id.RoomID]*roomInfo{}

	data, err := os.ReadFile(s.path)
	if err != nil {
		return rooms
	}

	var stored map[id.RoomID]persistedRoom
	if err := json.Unmarshal(data, &stored); err != nil {
		// A corrupt cache is not worth failing over: the rooms are re-fetched.
		return rooms
	}

	for roomID, p := range stored {
		info := newRoomInfo()
		info.Name = p.Name
		info.Alias = p.Alias
		info.Topic = p.Topic
		info.IsDirect = p.IsDirect
		info.IsSpace = p.IsSpace
		info.Encrypted = p.Encrypted
		info.Invited = p.Invited
		info.Left = p.Left
		info.InviteTS = p.InviteTS
		info.InvitedBy = id.UserID(p.InvitedBy)
		info.ReadUpTo = p.ReadUpTo
		info.LastEventID = id.EventID(p.LastEventID)
		info.LastEventTS = p.LastEventTS
		info.Tags = p.Tags
		for user, name := range p.Members {
			info.Members[id.UserID(user)] = name
		}
		rooms[roomID] = info
	}
	return rooms
}

func (s *roomStore) save(rooms map[id.RoomID]*roomInfo) {
	stored := make(map[id.RoomID]persistedRoom, len(rooms))

	for roomID, info := range rooms {
		p := persistedRoom{
			Name:      info.Name,
			Alias:     info.Alias,
			Topic:     info.Topic,
			IsDirect:  info.IsDirect,
			IsSpace:   info.IsSpace,
			Encrypted: info.Encrypted,
			Invited:   info.Invited,
			Left:      info.Left,
			InviteTS:  info.InviteTS,
			InvitedBy: string(info.InvitedBy),
			ReadUpTo:  info.ReadUpTo,

			LastEventID: string(info.LastEventID),
			LastEventTS: info.LastEventTS,

			Tags: info.Tags,
		}
		// Only worth keeping when they are what names the room.
		if len(info.Members) <= maxStoredMembers {
			p.Members = make(map[string]string, len(info.Members))
			for user, name := range info.Members {
				p.Members[string(user)] = name
			}
		}
		stored[roomID] = p
	}

	data, err := json.Marshal(stored)
	if err != nil {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, s.path)
}

// snapshotRooms copies the cache so it can be written without holding the lock
// across a file write.
func (b *bridge) snapshotRooms() map[id.RoomID]*roomInfo {
	b.mu.RLock()
	defer b.mu.RUnlock()

	out := make(map[id.RoomID]*roomInfo, len(b.rooms))
	for roomID, info := range b.rooms {
		copied := *info
		copied.Members = make(map[id.UserID]string, len(info.Members))
		for user, name := range info.Members {
			copied.Members[user] = name
		}
		out[roomID] = &copied
	}
	return out
}

func (b *bridge) persistRooms() {
	b.mu.RLock()
	store := b.roomStore
	b.mu.RUnlock()

	if store == nil {
		return
	}
	store.save(b.snapshotRooms())
}

// hydrate fills in rooms the cache does not know about.
//
// Only ever fetches rooms that would otherwise be shown as a raw id, so a normal
// start makes no requests at all. The first start after upgrading -- when there
// is a sync position but no room cache -- is the one that pays for it.
func (b *bridge) hydrate(ctx context.Context, client *mautrix.Client, roomIDs []id.RoomID) {
	var missing []id.RoomID
	for _, roomID := range roomIDs {
		if b.needsHydration(roomID) {
			missing = append(missing, roomID)
		}
	}
	if len(missing) == 0 {
		return
	}

	logf("info", "looking up %d rooms the local cache does not know yet", len(missing))

	// Bounded: an account in hundreds of rooms would otherwise open hundreds of
	// connections at once, and the homeserver would rate-limit the lot.
	const parallel = 4
	sem := make(chan struct{}, parallel)
	var wg sync.WaitGroup

	for _, roomID := range missing {
		wg.Add(1)
		go func(roomID id.RoomID) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			state, err := client.State(ctx, roomID)
			if err != nil {
				logf("debug", "could not read state for %s: %v", roomID, err)
				return
			}
			b.applyState(roomID, state)
		}(roomID)
	}
	wg.Wait()
}

func (b *bridge) needsHydration(roomID id.RoomID) bool {
	b.mu.RLock()
	defer b.mu.RUnlock()

	info, ok := b.rooms[roomID]
	if !ok {
		return true
	}
	// Anything that can produce a name is enough; only a room with none of them
	// would fall back to its id.
	return info.Name == "" && info.Alias == "" && len(info.Members) == 0
}

// applyState feeds fetched state through the same handlers the sync loop uses,
// so there is one place that decides what a state event means.
func (b *bridge) applyState(roomID id.RoomID, state mautrix.RoomStateMap) {
	ctx := context.Background()

	for _, eventType := range []event.Type{
		event.StateCreate,
		event.StateRoomName,
		event.StateCanonicalAlias,
		event.StateTopic,
		event.StateEncryption,
		event.StateMember,
	} {
		for _, evt := range state[eventType] {
			if evt == nil {
				continue
			}
			// mautrix already parsed these while decoding the state array.
			// Re-parsing can fail on already-consumed content, and skipping on
			// that error silently discarded every event.
			if evt.Content.Parsed == nil {
				_ = evt.Content.ParseRaw(evt.Type)
			}
			evt.RoomID = roomID

			switch eventType {
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
			case event.StateMember:
				b.onMember(ctx, evt)
			}
		}
	}
}

// loadRoomCache opens the cache, tolerating a store that cannot be created.
//
// A missing cache is a slow start, not a broken one: the rooms are fetched from
// the server instead.
func loadRoomCache() (map[id.RoomID]*roomInfo, *roomStore) {
	store, err := newRoomStore()
	if err != nil {
		logf("debug", "no room cache available: %v", err)
		return nil, nil
	}
	return store.load(), store
}
