package main

import (
	"context"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// A Matrix room has no single "name" field. It may have m.room.name, or only a
// published alias, or neither -- a direct message usually has neither, and is
// named after whoever else is in it. This file is the whole of that reckoning.

type roomInfo struct {
	Name      string
	Alias     string
	Topic     string
	AvatarURL id.ContentURI

	IsDirect  bool
	IsSpace   bool
	Encrypted bool

	// Invited is a room we have been asked to join but have not joined, and
	// Left one we are no longer in -- because we declined, or left from another
	// client. Neither is an ordinary conversation: an invitation has no
	// timeline of its own, and a room we are not in has stopped being one.
	Invited bool
	Left    bool

	// InviteTS is when the invitation was first seen and InvitedBy who sent it.
	// An invitation carries no messages, so without a time of our own the host
	// -- which orders conversations by their last activity and shows none that
	// have any -- would never surface it.
	InviteTS  int64
	InvitedBy id.UserID

	// ReadUpTo is the timestamp of our own newest read receipt in this room --
	// the one Matrix keeps, which every client of ours updates. It is what
	// tells the host that a conversation read elsewhere is not unread here.
	ReadUpTo int64

	// LastEventID is the newest event this room has shown us, and LastEventTS
	// when it happened.
	//
	// Kept for the other direction: the host marks a conversation read at a
	// moment in time, while Matrix hangs a read receipt on an event. This is
	// what turns the one into the other, and without it reading a room here
	// tells nobody else -- see handleMarkRead.
	LastEventID id.EventID
	LastEventTS int64

	// Members maps a user to their display name in this room. Display names are
	// per-room in Matrix: the same account can be "Ada" in one and "A." in
	// another, and using the wrong one mislabels every message they send.
	Members map[id.UserID]string

	// Tags are the room's m.tag account data: favourite, low priority.
	Tags []string

	// MemberAvatars maps a member to their picture in this room, which is
	// per-room in Matrix just as a display name is.
	MemberAvatars map[id.UserID]id.ContentURI

	// BackfillToken is where paging back through this room's history carries
	// on from, and BackfillTS the time of the oldest event it lies behind.
	// BackfillDone is the beginning reached: there is nothing older to fetch.
	// See history.go.
	BackfillToken string
	BackfillTS    int64
	BackfillDone  bool

	// PushMuted is whether the account's push rules mute this room -- what
	// Element's Mute does -- as last told to the host. See pushrules.go.
	PushMuted bool
}

func newRoomInfo() *roomInfo {
	return &roomInfo{Members: map[id.UserID]string{}, MemberAvatars: map[id.UserID]id.ContentURI{}}
}

// room returns the cached room, creating it if this is the first time we have
// heard of it.
func (b *bridge) room(roomID id.RoomID) *roomInfo {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.roomLocked(roomID)
}

func (b *bridge) roomLocked(roomID id.RoomID) *roomInfo {
	info, ok := b.rooms[roomID]
	if !ok {
		info = newRoomInfo()
		b.rooms[roomID] = info
	}
	return info
}

// updateRoom changes a room's record under the lock.
//
// Every write to a room goes through here or holds the lock itself. The sync
// loop, the hydration workers and the catch-up all write these records while
// publishing reads them from goroutines of its own, and a write that skipped the
// lock was a torn string at best -- at worst a member map changing under a range
// over it, which Go does not count as a race to forgive: it stops the program.
func (b *bridge) updateRoom(roomID id.RoomID, change func(info *roomInfo)) {
	b.mu.Lock()
	defer b.mu.Unlock()
	change(b.roomLocked(roomID))
}

// displayName resolves a room's name the way the Matrix spec asks for it.
//
// The fallback chain matters more here than in most services, because the
// common case -- a direct message -- has neither a name nor an alias, and would
// otherwise show as a raw room id.
//
// The read lock is held to the end, not just for the lookup: the member map
// ranged over below is written by the sync loop while this runs from the
// publishing goroutines, and the runtime ends the process when it catches a map
// being written mid-range.
func (b *bridge) displayName(roomID id.RoomID) string {
	b.mu.RLock()
	defer b.mu.RUnlock()

	info, ok := b.rooms[roomID]
	// selfIDLocked, not selfID: taking RLock again while already holding it
	// deadlocks as soon as a writer is queued between the two acquisitions.
	self := b.selfIDLocked()

	if !ok {
		return string(roomID)
	}

	if n := strings.TrimSpace(info.Name); n != "" {
		return n
	}
	if a := strings.TrimSpace(info.Alias); a != "" {
		return a
	}

	// Name it after everyone who is not us.
	others := make([]string, 0, len(info.Members))
	for user, name := range info.Members {
		if user == self {
			continue
		}
		if name = strings.TrimSpace(name); name != "" && name != string(user) {
			others = append(others, name)
		} else {
			others = append(others, fallbackName(user))
		}
	}
	sort.Strings(others)

	switch len(others) {
	case 0:
		// Everyone else left, or we are alone in a note-to-self room.
		return "Empty room"
	case 1:
		return others[0]
	case 2:
		return others[0] + " and " + others[1]
	default:
		return others[0] + " and " + strconv.Itoa(len(others)-1) + " others"
	}
}

// senderName is how this person is called in this room.
//
// A name the room does not know yet is asked for, once: the sync lazily loads
// members, sending each one's name only the first time this device needs it,
// and the names of a big room's members are not kept across a restart -- so
// after one, everybody who had spoken before it went by their raw account id
// for good. Failing that, the account id made readable; see fallbackName.
func (b *bridge) senderName(roomID id.RoomID, user id.UserID) string {
	b.mu.RLock()
	name := ""
	if info, ok := b.rooms[roomID]; ok {
		name = strings.TrimSpace(info.Members[user])
	}
	b.mu.RUnlock()

	if name != "" && name != string(user) {
		return name
	}
	if looked := b.lookUpName(roomID, user); looked != "" {
		return looked
	}
	return fallbackName(user)
}

// nameLookupTimeout bounds the one question about a member's name, which is
// asked while a message is being read in.
const nameLookupTimeout = 4 * time.Second

// lookUpName asks the homeserver what a member is called in a room, once per
// member and room for as long as the bridge runs, and "" when it does not say.
func (b *bridge) lookUpName(roomID id.RoomID, user id.UserID) string {
	key := string(roomID) + " " + string(user)

	b.mu.Lock()
	if name, asked := b.lookedUpNames[key]; asked {
		b.mu.Unlock()
		return name
	}
	client := b.client
	if client == nil || user == "" {
		b.mu.Unlock()
		return ""
	}
	if b.lookedUpNames == nil {
		b.lookedUpNames = map[string]string{}
	}
	// Recorded before asking, so a second message from them while the
	// question is out does not ask again.
	b.lookedUpNames[key] = ""
	b.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), nameLookupTimeout)
	defer cancel()
	var member event.MemberEventContent
	if err := client.StateEvent(ctx, roomID, event.StateMember, string(user), &member); err != nil {
		logf("debug", "could not look up the name of %s: %v", user, err)
		return ""
	}
	name := strings.TrimSpace(member.Displayname)

	b.mu.Lock()
	b.lookedUpNames[key] = name
	if name != "" && (member.Membership == event.MembershipJoin || member.Membership == event.MembershipInvite) {
		if info, ok := b.rooms[roomID]; ok {
			if known := strings.TrimSpace(info.Members[user]); known == "" || known == string(user) {
				info.Members[user] = name
			}
		}
	}
	b.mu.Unlock()
	return name
}

// fallbackName is what an account with no display name is called: not its
// whole id, "@whatsapp_lid-26139372290197:example.net", but the part that
// means something -- a bridged phone number as the number, any other bridged
// account as its service and the end of its id, an ordinary account as the
// name before the server.
func fallbackName(user id.UserID) string {
	local := user.Localpart()
	if local == "" {
		return string(user)
	}
	m := puppetLocalpart.FindStringSubmatch(local)
	if m == nil {
		return local
	}
	service, lid, rest := m[1], m[2], m[3]
	if service == "whatsapp" && lid == "" && allDigits(rest) {
		return "+" + rest
	}
	tail := strings.ReplaceAll(rest, "-", "")
	if len(tail) > 4 {
		tail = tail[len(tail)-4:]
	}
	return puppetServices[service] + " …" + tail
}

// The accounts bridges make for the people they bring in: "whatsapp_<number>",
// "whatsapp_lid-<id>", "signal_<uuid>", "telegram_<id>".
var puppetLocalpart = regexp.MustCompile(`^(whatsapp|signal|telegram|discord|instagram|meta|facebook|slack|gmessages|imessage|linkedin|twitter|bluesky)_(lid-)?([0-9a-zA-Z_=.\-]+)$`)

var puppetServices = map[string]string{
	"whatsapp":  "WhatsApp",
	"signal":    "Signal",
	"telegram":  "Telegram",
	"discord":   "Discord",
	"instagram": "Instagram",
	"meta":      "Messenger",
	"facebook":  "Messenger",
	"slack":     "Slack",
	"gmessages": "SMS",
	"imessage":  "iMessage",
	"linkedin":  "LinkedIn",
	"twitter":   "Twitter",
	"bluesky":   "Bluesky",
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// handlesFor lists what a user might type to reach this room.
//
// A Matrix room id is an opaque, unguessable string, so without these the room
// could only be found by name. The alias is what people actually share, and for
// a direct message the other person's user id is what you would search for.
func (b *bridge) handlesFor(roomID id.RoomID) []string {
	b.mu.RLock()
	defer b.mu.RUnlock()

	info, ok := b.rooms[roomID]
	if !ok {
		return nil
	}

	var out []string
	seen := map[string]bool{}
	add := func(h string) {
		h = strings.TrimSpace(h)
		if h == "" || seen[h] {
			return
		}
		seen[h] = true
		out = append(out, h)
	}

	add(info.Alias)

	// Only for direct messages. In a room of four hundred people, every member
	// id would become a handle, and searching any one of them would surface the
	// room rather than the person.
	if info.IsDirect {
		self := b.selfIDLocked()
		for user := range info.Members {
			if user != self {
				add(string(user))
			}
		}
	}
	return out
}

// tagsFor labels a room.
//
// Only what the host cannot work out for itself: it already derives group,
// direct, unread, muted and archived. These are Matrix's own ideas.
func (b *bridge) tagsFor(roomID id.RoomID) []string {
	b.mu.RLock()
	defer b.mu.RUnlock()

	// Never nil: an omitted tag list means "no opinion" to the host, which
	// keeps whatever it already had. Only an empty one can take a tag off a
	// room -- which is exactly what accepting an invitation has to do.
	tags := []string{}

	info, ok := b.rooms[roomID]
	if !ok {
		return tags
	}

	if info.IsSpace {
		// A space is a container for rooms, not a conversation. Tagged rather
		// than dropped so the filter is the user's to set.
		tags = append(tags, "space")
	}
	if info.Invited {
		tags = append(tags, "invite")
	}
	if info.Encrypted {
		tags = append(tags, "encrypted")
	}
	for _, t := range info.Tags {
		switch t {
		case "m.favourite":
			tags = append(tags, "favourite")
		case "m.lowpriority":
			tags = append(tags, "lowPriority")
		case "m.server_notice":
			tags = append(tags, "serverNotice")
		}
	}
	return tags
}

func (b *bridge) selfID() id.UserID {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.selfIDLocked()
}

func (b *bridge) selfIDLocked() id.UserID {
	if b.sess == nil {
		return ""
	}
	return id.UserID(b.sess.UserID)
}
