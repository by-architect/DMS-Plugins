package main

import (
	"context"
	"encoding/json"
	"errors"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
	"maunium.net/go/mautrix/pushrules"
)

// The account's own notification settings.
//
// Matrix keeps them on the homeserver, as push rules every client of the
// account shares: a room set to "Mentions and keywords" in Element, a room
// muted, keywords that should always notify, notifications off for the whole
// account. DMS knew none of it, and notified for every message in every room --
// so the room muted on the phone a year ago was the noisiest thing on the
// desktop.
//
// Now each arriving message is judged by those rules, the way the homeserver
// judges it for a phone: one they would not notify for is marked silent, and
// one that mentions us is marked as a highlight, which gets through even where
// group notifications are off. And a room's mute goes both ways -- muted in
// Element, it is muted here; muted here, it is muted in Element.
//
// All of it can be switched off on the plugin's settings page, which leaves
// notifications to DMS's own settings alone, as they were.

// useMatrixNotifications is whether the account's push rules decide.
func (b *bridge) useMatrixNotifications() bool {
	return b.settingBool("useMatrixNotifications", true)
}

// onPushRules keeps the account's rules as the sync delivers them. Which rooms
// they mute is worked out once the whole response is in -- see reportMutes --
// since a first sync brings the rules before the rooms they name.
func (b *bridge) onPushRules(ctx context.Context, evt *event.Event) {
	content, ok := evt.Content.Parsed.(*pushrules.EventContent)
	if !ok || content.Ruleset == nil {
		return
	}
	b.mu.Lock()
	b.pushRules = content.Ruleset
	b.mu.Unlock()
}

// loadPushRules asks the homeserver for the account's rules. Failing that, the
// sync brings them the next time they change, and until then DMS's own
// settings decide alone, as they always did.
func (b *bridge) loadPushRules(ctx context.Context, client *mautrix.Client) {
	rules, err := client.GetPushRules(ctx)
	if err != nil {
		logf("debug", "could not read the account's notification settings: %v", err)
		return
	}
	b.mu.Lock()
	if b.pushRules == nil {
		// Not over what a sync may already have brought, which is newer.
		b.pushRules = rules
	}
	b.mu.Unlock()
}

// pushRoom is what the rules need to know about a room.
type pushRoom struct {
	ownName string
	members int
}

func (r pushRoom) GetOwnDisplayname() string { return r.ownName }
func (r pushRoom) GetMemberCount() int       { return r.members }

// notificationHints judges a message arriving now by the account's push rules:
// whether they would leave it silent, and whether it is a highlight. Neither,
// while the rules are not known yet or the user has turned this off -- DMS's
// own settings then decide alone.
func (b *bridge) notificationHints(evt *event.Event) (silent, highlight bool) {
	if !b.useMatrixNotifications() {
		return false, false
	}

	b.mu.RLock()
	rules := b.pushRules
	room := pushRoom{}
	if info := b.rooms[evt.RoomID]; info != nil {
		room.members = len(info.Members)
		room.ownName = info.Members[b.selfIDLocked()]
	}
	b.mu.RUnlock()

	if rules == nil {
		return false, false
	}
	should := rules.GetActions(room, evt).Should()
	return !should.Notify, should.Highlight
}

// mutedRooms lists the rooms the rules mute: an enabled override rule that
// names the room and does not notify, which is what Element's Mute writes.
//
// "Mentions and keywords" is a room rule instead, and deliberately not a mute:
// the room still has unread messages worth seeing, it just interrupts nobody
// unless they are named -- which notificationHints takes care of.
func mutedRooms(rules *pushrules.PushRuleset) map[id.RoomID]bool {
	muted := map[id.RoomID]bool{}
	if rules == nil {
		return muted
	}
	for _, rule := range rules.Override {
		if rule == nil || !rule.Enabled || rule.Actions.Should().Notify {
			continue
		}
		if len(rule.Conditions) != 1 {
			continue
		}
		cond := rule.Conditions[0]
		if cond.Kind == pushrules.KindEventMatch && cond.Key == "room_id" && cond.Pattern == rule.RuleID {
			muted[id.RoomID(rule.RuleID)] = true
		}
	}
	return muted
}

// reportMutes tells the host about every room whose mute on Matrix has changed
// since it was last told.
//
// Only changes, never the whole picture: a room muted in DMS before any of this
// existed is left muted, and a mute set here that could not reach Matrix is not
// undone by the next republish. The first time the rules are seen, that means
// the rooms they mute are reported muted, and nothing else is said.
func (b *bridge) reportMutes() {
	if !b.useMatrixNotifications() {
		return
	}

	type change struct {
		roomID id.RoomID
		muted  bool
	}
	var changes []change

	b.mu.Lock()
	if b.pushRules == nil {
		b.mu.Unlock()
		return
	}
	muted := mutedRooms(b.pushRules)
	for roomID, info := range b.rooms {
		if now := muted[roomID]; now != info.PushMuted {
			info.PushMuted = now
			changes = append(changes, change{roomID: roomID, muted: now})
		}
	}
	b.mu.Unlock()

	if len(changes) == 0 {
		return
	}
	for _, c := range changes {
		if b.hasLeft(c.roomID) {
			continue
		}
		chat := b.chatFor(c.roomID)
		value := c.muted
		chat.Muted = &value
		emitEvent("chat", map[string]any{"chat": chat})
	}
	go b.persistRooms()
}

// handleSetMuted carries a mute set in DMS to the account's push rules, so the
// room is quiet on every other client too: the override rule Element's Mute
// writes, or that rule taken away.
func (b *bridge) handleSetMuted(ctx context.Context, c call) {
	var params struct {
		ChatID string `json:"chatId"`
		Muted  bool   `json:"muted"`
	}
	_ = json.Unmarshal(c.Params, &params)

	if !b.useMatrixNotifications() || params.ChatID == "" {
		ok(c.ID, nil)
		return
	}
	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return
	}

	roomID := id.RoomID(params.ChatID)
	if err := setRoomMuted(ctx, client, roomID, params.Muted); err != nil {
		fail(c.ID, "mute_failed", "%s", serverMessage(err, "could not change the room's notifications"))
		return
	}

	// What the host already knows, so the rules coming back in the next sync
	// are not reported to it as news.
	b.updateRoom(roomID, func(info *roomInfo) { info.PushMuted = params.Muted })
	go b.persistRooms()
	ok(c.ID, nil)
}

// pushRuleWriter is the slice of the client that changing a push rule needs.
type pushRuleWriter interface {
	PutPushRule(ctx context.Context, scope string, kind pushrules.PushRuleType, ruleID string, req *mautrix.ReqPutPushRule) error
	DeletePushRule(ctx context.Context, scope string, kind pushrules.PushRuleType, ruleID string) error
}

func setRoomMuted(ctx context.Context, client pushRuleWriter, roomID id.RoomID, muted bool) error {
	if !muted {
		err := client.DeletePushRule(ctx, "global", pushrules.OverrideRule, string(roomID))
		if errors.Is(err, mautrix.MNotFound) {
			// Not muted on Matrix to begin with.
			return nil
		}
		return err
	}
	return client.PutPushRule(ctx, "global", pushrules.OverrideRule, string(roomID), &mautrix.ReqPutPushRule{
		// No actions is "do not notify", as the spec now spells it.
		Actions: []*pushrules.PushAction{},
		Conditions: []*pushrules.PushCondition{{
			Kind:    pushrules.KindEventMatch,
			Key:     "room_id",
			Pattern: string(roomID),
		}},
	})
}
