package main

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Catching up on state that a resumed sync will never mention again.
//
// A homeserver tells a client what changed since its last position, which is
// exactly right for messages and exactly wrong for standing state. An
// invitation is announced once. A read receipt is sent once. A bridge that
// learns to care about either of them only ever hears about the next one, and
// carries on misreporting everything already sitting there -- rooms read on a
// phone last week showing unread, invitations nobody can see.
//
// So the first run that knows about a given kind of state asks for it outright,
// once, and writes down that it has. The version below is what makes "once"
// mean once per kind rather than once ever: bump it and every installation
// re-checks one more time.
const catchUpVersion = 1

// catchUpFilter asks for standing state and almost no content.
//
// Without a filter this is a full initial sync, which on a busy account means
// megabytes of timeline for the sake of a few receipts. The timeline is capped
// at one event rather than none because some homeservers treat zero as absent.
const catchUpFilter = `{"presence":{"types":[]},"account_data":{"types":[]},` +
	`"room":{"account_data":{"types":[]},"ephemeral":{"types":["m.receipt"]},` +
	`"timeline":{"limit":1},` +
	`"state":{"lazy_load_members":true,"types":["m.room.create","m.room.name",` +
	`"m.room.canonical_alias","m.room.topic","m.room.avatar","m.room.encryption","m.room.member"]}}}`

// catchUp recovers pending invitations and read positions, at most once per
// version.
//
// Runs before the sync loop rather than beside it, deliberately: everything it
// learns changes whether an arriving message is worth a notification, and a
// verdict reached before the answer has landed is the wrong one.
func (b *bridge) catchUp(ctx context.Context, client *mautrix.Client) {
	if !b.catchUpNeeded() {
		return
	}

	logf("info", "checking for invitations and read receipts this device has not seen")

	resp, err := client.FullSyncRequest(ctx, mautrix.ReqSync{FilterID: catchUpFilter})
	if err != nil {
		// Left unrecorded on purpose, so the next start tries again.
		logf("debug", "could not catch up on invitations and read receipts: %v", err)
		return
	}
	// Recorded before the work, not after: a marker that only appears on a
	// perfect run repeats this whole sync on every start until one is.
	b.recordCatchUp()

	self := b.selfID()

	var invites []id.RoomID
	for roomID, invited := range resp.Rooms.Invite {
		if invited != nil {
			b.applyStrippedState(roomID, invited.State.Events)
		}
		if b.noteInvite(roomID, inviterOf(invited, self)) {
			invites = append(invites, roomID)
		}
	}

	var read []id.RoomID
	for roomID, joined := range resp.Rooms.Join {
		if joined == nil {
			continue
		}
		// Only our own receipt. Everyone else's says who has read our messages,
		// which the sync loop reports as it happens and which would be
		// thousands of status frames about messages this device never had.
		if ts := ourReadReceipt(joined.Ephemeral.Events, self); ts > 0 && b.setReadUpTo(roomID, ts) {
			read = append(read, roomID)
		}
	}

	if len(invites) > 0 {
		logf("info", "found %d invitation(s) waiting", len(invites))
	}
	if len(read) > 0 {
		logf("info", "caught up on where %d conversation(s) had been read", len(read))
	}

	b.publishChunked(append(invites, read...))
	if len(invites) > 0 || len(read) > 0 {
		b.persistRooms()
	}
}

// ourReadReceipt returns when we last read this room, from the receipts in one
// sync response, or zero if they say nothing about us.
func ourReadReceipt(events []*event.Event, self id.UserID) int64 {
	if self == "" {
		return 0
	}

	var newest int64
	for _, evt := range events {
		if evt == nil || evt.Type != event.EphemeralEventReceipt {
			continue
		}
		if evt.Content.Parsed == nil {
			_ = evt.Content.ParseRaw(evt.Type)
		}
		content, ok := evt.Content.Parsed.(*event.ReceiptEventContent)
		if !ok {
			continue
		}

		for _, receipts := range *content {
			for receiptType, users := range receipts {
				switch receiptType {
				case event.ReceiptTypeRead, event.ReceiptTypeReadPrivate:
				default:
					continue
				}
				if ts := users[self].Timestamp.UnixMilli(); ts > newest {
					newest = ts
				}
			}
		}
	}
	// A receipt with no timestamp reads as the epoch once converted, which is
	// not a read position; treat it as nothing rather than as 1970.
	if newest <= 0 {
		return 0
	}
	return newest
}

// publishChunked republishes rooms in batches the host can write in one
// transaction each, rather than as a single frame of everything.
func (b *bridge) publishChunked(roomIDs []id.RoomID) {
	const batchSize = 200

	for start := 0; start < len(roomIDs); start += batchSize {
		end := start + batchSize
		if end > len(roomIDs) {
			end = len(roomIDs)
		}
		b.publishSome(roomIDs[start:end])
	}
}

// ---------------------------------------------------------------- the marker

func catchUpPath() (string, error) {
	dir, err := stateDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "catchup"), nil
}

func (b *bridge) catchUpNeeded() bool {
	path, err := catchUpPath()
	if err != nil {
		return false
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return true
	}
	done, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return true
	}
	return done < catchUpVersion
}

func (b *bridge) recordCatchUp() {
	path, err := catchUpPath()
	if err != nil {
		return
	}
	_ = os.WriteFile(path, []byte(strconv.Itoa(catchUpVersion)+"\n"), 0o600)
}
