package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Starting a conversation from here: a direct chat with @someone:server, or
// joining a room by its #address:server or !id.
//
// There was no way to do either. A conversation existed in DMS only once it had
// been started from another client, which for someone whose only client this
// is meant never.

// startChatBudget bounds starting one conversation.
const startChatBudget = 25 * time.Second

// handleStartChat opens the conversation a handle names, answering with its id
// and name.
func (b *bridge) handleStartChat(ctx context.Context, c call) {
	var params struct {
		Handle string `json:"handle"`
	}
	_ = json.Unmarshal(c.Params, &params)

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return
	}

	self := b.selfID()
	handle := strings.TrimSpace(params.Handle)

	// Under the host's own wait: a profile on a far-off server, or a room
	// being joined over federation, can take a long time to answer, and a
	// conversation that turns up after the host has given up is one nobody
	// asked to see.
	ctx, cancel := context.WithTimeout(ctx, startChatBudget)
	defer cancel()

	var roomID id.RoomID
	var fresh bool
	var err error
	switch {
	case strings.HasPrefix(handle, "@"):
		roomID, fresh, err = b.directChatWith(ctx, client, id.UserID(withServer(handle, self)))
	case strings.HasPrefix(handle, "#"), strings.HasPrefix(handle, "!"):
		roomID, fresh, err = b.joinRoom(ctx, client, withServer(handle, self))
	default:
		err = errors.New("type a Matrix address: @name:server for a person, or #room:server for a room")
	}
	if err != nil {
		fail(c.ID, "start_failed", "%s", err.Error())
		return
	}

	// Named before it is published: a room just joined has nothing in this
	// device's cache yet, and would otherwise open under its id.
	b.hydrate(ctx, client, []id.RoomID{roomID})
	if fresh {
		b.emitStartLine(roomID)
	}
	b.publishSome([]id.RoomID{roomID})
	go b.persistRooms()

	ok(c.ID, map[string]any{"chatId": string(roomID), "name": b.displayName(roomID)})
}

// withServer completes a handle typed without its server -- "@ada", "#lobby" --
// with our own, which is what people mean by it. Room ids are left alone: a new
// room version's ids have no server in them at all.
func withServer(handle string, self id.UserID) string {
	if strings.HasPrefix(handle, "!") || strings.Contains(handle, ":") {
		return handle
	}
	if server := self.Homeserver(); server != "" {
		return handle + ":" + server
	}
	return handle
}

// joinRoom joins a room by address or id, reporting whether it is a room we
// were not in before.
func (b *bridge) joinRoom(ctx context.Context, client *mautrix.Client, address string) (id.RoomID, bool, error) {
	resp, err := client.JoinRoom(ctx, address, nil)
	if err != nil {
		return "", false, errors.New(serverMessage(err, "could not join "+address))
	}

	b.mu.Lock()
	info := b.roomLocked(resp.RoomID)
	fresh := info.LastEventTS == 0 || info.Left || info.Invited
	info.Invited, info.Left = false, false
	b.mu.Unlock()

	logf("info", "joined %s", resp.RoomID)
	return resp.RoomID, fresh, nil
}

// directChatWith finds our direct chat with someone, or starts one, reporting
// whether it is new.
//
// A new one is created the way Element creates one: private, marked as direct
// for both sides, and encrypted from its first event. Without encryption
// working here it is not created at all -- a private conversation that quietly
// started in plain text would be worse than none.
func (b *bridge) directChatWith(ctx context.Context, client *mautrix.Client, user id.UserID) (id.RoomID, bool, error) {
	self := b.selfID()
	if user == self {
		return "", false, errors.New("that is your own address")
	}
	if _, _, err := user.ParseAndValidateRelaxed(); err != nil {
		return "", false, fmt.Errorf("%s is not a Matrix address; people's look like @name:server", user)
	}

	if existing := b.existingDirect(user); existing != "" {
		return existing, false, nil
	}

	// Somebody has to be there to talk to. A homeserver that cannot be asked
	// -- another server unreachable, profiles kept private -- proves nothing,
	// and the invitation itself will say.
	name := ""
	if profile, err := client.GetProfile(ctx, user); err == nil {
		name = strings.TrimSpace(profile.DisplayName)
	} else if errors.Is(err, mautrix.MNotFound) {
		return "", false, fmt.Errorf("nobody is signed up as %s", user)
	}

	if b.currentCrypto() == nil {
		return "", false, errors.New("encryption is not working on this device, so a private conversation cannot be started safely")
	}

	empty := ""
	resp, err := client.CreateRoom(ctx, &mautrix.ReqCreateRoom{
		Preset:   "trusted_private_chat",
		IsDirect: true,
		Invite:   []id.UserID{user},
		InitialState: []*event.Event{{
			Type:     event.StateEncryption,
			StateKey: &empty,
			Content:  event.Content{Parsed: &event.EncryptionEventContent{Algorithm: id.AlgorithmMegolmV1}},
		}},
	})
	if err != nil {
		return "", false, errors.New(serverMessage(err, "could not start the conversation"))
	}

	// mautrix decides whether to encrypt, and whom to share the key with, by
	// its own state store, which hears about this room only when the sync gets
	// round to it. A message typed before then would have gone out in plain
	// text, or encrypted to nobody -- so it is told now.
	if store := client.StateStore; store != nil {
		_ = store.SetEncryptionEvent(ctx, resp.RoomID, &event.EncryptionEventContent{Algorithm: id.AlgorithmMegolmV1})
		_ = store.SetMembership(ctx, resp.RoomID, self, event.MembershipJoin)
		_ = store.SetMembership(ctx, resp.RoomID, user, event.MembershipInvite)
	}

	if name == "" {
		name = string(user)
	}
	b.updateRoom(resp.RoomID, func(info *roomInfo) {
		info.IsDirect = true
		info.Encrypted = true
		info.Invited, info.Left = false, false
		info.Members[user] = name
	})

	if err := b.markDirect(ctx, client, user, resp.RoomID); err != nil {
		// The room works either way; only other clients' idea of it differs.
		logf("warn", "could not record %s as a direct chat: %v", resp.RoomID, err)
	}
	logf("info", "started a direct chat with %s", user)
	return resp.RoomID, true, nil
}

// existingDirect finds a direct chat with one person that we are still in,
// the one most recently written in when there are several.
func (b *bridge) existingDirect(user id.UserID) id.RoomID {
	b.mu.RLock()
	defer b.mu.RUnlock()

	self := b.selfIDLocked()
	var best id.RoomID
	var bestTS int64 = -1
	for roomID, info := range b.rooms {
		if !info.IsDirect || info.Left || info.Invited || info.IsSpace {
			continue
		}
		if _, ok := info.Members[user]; !ok {
			continue
		}
		others := 0
		for member := range info.Members {
			if member != self {
				others++
			}
		}
		if others != 1 {
			continue
		}
		if info.LastEventTS > bestTS {
			best, bestTS = roomID, info.LastEventTS
		}
	}
	return best
}

// markDirect adds a room to the account's m.direct, which is how every client
// of the account knows it is a one-to-one conversation rather than a room.
func (b *bridge) markDirect(ctx context.Context, client *mautrix.Client, user id.UserID, roomID id.RoomID) error {
	direct := event.DirectChatsEventContent{}
	if err := client.GetAccountData(ctx, event.AccountDataDirectChats.Type, &direct); err != nil && !errors.Is(err, mautrix.MNotFound) {
		return err
	}
	for _, known := range direct[user] {
		if known == roomID {
			return nil
		}
	}
	direct[user] = append(direct[user], roomID)
	return client.SetAccountData(ctx, event.AccountDataDirectChats.Type, direct)
}

// emitStartLine gives a conversation just started or joined its first line,
// the way an invitation has one: a system row, never unread and never a
// notification, which is also the activity that puts it in the list.
func (b *bridge) emitStartLine(roomID id.RoomID) {
	b.mu.RLock()
	direct := false
	if info := b.rooms[roomID]; info != nil {
		direct = info.IsDirect
	}
	b.mu.RUnlock()

	text := "You joined this room"
	if direct {
		text = "You started this conversation"
	}
	emitEvent("message", map[string]any{"message": messageObj{
		ID:     string(roomID) + "/start",
		ChatID: string(roomID),
		TS:     time.Now().UnixMilli(),
		FromMe: true,
		Kind:   "system",
		Text:   text,
	}})
}
