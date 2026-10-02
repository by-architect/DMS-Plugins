package main

import (
	"context"
	"slices"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// handleWhatsAppEvent is the whole inbound path: whatsmeow events in, contract
// events out. Everything WhatsApp-shaped stops here.
func (b *bridge) handleWhatsAppEvent(evt any) {
	switch v := evt.(type) {

	case *events.Connected:
		// Not "connected" yet. WhatsApp is about to replay everything that
		// arrived while this device was away, and the host holds notifications
		// until it hears connected, then judges what was held against what has
		// been read elsewhere. Saying it here, before the replay, meant every
		// message in a long backlog that landed after the host's short grace
		// period was announced one by one. OfflineSyncCompleted is the real end
		// of the catch-up; the backstop covers a replay that never says so.
		b.armConnectedBackstop()
		go b.syncChats(context.Background())

	case *events.Disconnected:
		// Routine: whatsmeow reconnects on its own. Reported so the UI shows
		// the truth, but not logged as an error.
		emitState("disconnected")

	case *events.LoggedOut:
		logf("warn", "logged out by WhatsApp (%s)", v.Reason)
		emitState("needsLogin")

	case *events.StreamReplaced:
		// Another client took over this session.
		logf("warn", "session replaced by another device")
		emitState("disconnected")

	case *events.ConnectFailure:
		logf("error", "connection failed: %s", v.Reason)
		emitState("disconnected")

	case *events.ClientOutdated:
		// WhatsApp refuses this version of the protocol library outright, and
		// whatsmeow does not retry. Without this the provider sat at
		// "connecting" with nothing in the log to say why.
		logf("error", "WhatsApp rejected this client as outdated; rebuild the bridge against a newer whatsmeow (./build.sh)")
		emitState("disconnected")

	case *events.TemporaryBan:
		// Likewise final until it expires, and likewise silent before.
		logf("error", "%s", v.String())
		emitState("disconnected")

	case *events.Message:
		b.onMessage(v)

	case *events.Receipt:
		b.onReceipt(v)

	case *events.MarkChatAsRead:
		// "Mark as read" on another device. Only the read direction can be
		// passed on: the host's read position only ever moves forward.
		if v.Action.GetRead() && !v.Timestamp.IsZero() {
			b.readElsewhere(v.JID.String(), v.Timestamp.UnixMilli())
		}

	case *events.GroupInfo:
		// A rename. Kept in step here because names are cached rather than
		// asked for on every message, and published at once so the list shows
		// the new subject without waiting for someone to write.
		if v.Name != nil && v.Name.Name != "" {
			b.mu.Lock()
			b.groupNames[v.JID] = v.Name.Name
			b.mu.Unlock()
			emitEvent("chat", map[string]any{"chat": chatObj{ID: v.JID.String(), Name: v.Name.Name, IsGroup: true}})
		}

	case *events.HistorySync:
		b.onHistorySync(v)

	case *events.OfflineSyncCompleted:
		// The catch-up burst is over; the host can stop showing progress, and
		// what it held back during the replay can now be judged.
		emitEvent("sync", map[string]any{"done": 0, "total": 0})
		emitState("connected")
	}
}

// offlineSyncLimit is how long after the socket comes up "connected" waits for
// the offline replay to report that it has finished.
//
// A backstop, not the normal path: OfflineSyncCompleted arrives within a second
// or two of an ordinary reconnect. It only has to be short enough that a
// replay which never reports finishing does not leave the provider looking
// stuck, and the host flushes anything it held after 45s regardless.
const offlineSyncLimit = 15 * time.Second

// armConnectedBackstop reports connected if the offline replay does not.
//
// Saying connected twice is harmless -- it is a state, not an event -- which is
// what keeps this simple: the replay may finish before or after this fires, and
// either order ends in the same place. Checking the client first keeps a timer
// from a connection that has since dropped from claiming the new one is up.
func (b *bridge) armConnectedBackstop() {
	time.AfterFunc(offlineSyncLimit, func() {
		if client := b.getClient(); client != nil && client.IsLoggedIn() {
			emitState("connected")
		}
	})
}

// onMessage converts a single incoming or echoed message.
func (b *bridge) onMessage(evt *events.Message) {
	msg := b.convertLive(evt.Info, evt.Message)
	if msg == nil {
		return
	}

	emitEvent("message", map[string]any{"message": msg})

	// Remembered so that reading it here can send the receipt WhatsApp wants,
	// which names the message rather than a point in time.
	if !evt.Info.IsFromMe {
		b.noteUnread(msg.ChatID, unreadRef{id: evt.Info.ID, sender: evt.Info.Sender, ts: msg.TS})
	}

	// Fetch the attachment in the background and re-emit once it has landed.
	// Only for live messages: doing this during backfill would download years
	// of media the moment a device is linked.
	if msg.MediaRef != "" {
		go b.autoDownload(*msg)
	}

	// Keep the conversation's activity line in step. The host would derive it
	// anyway, but sending it means the chat list reorders immediately.
	emitEvent("chat", map[string]any{"chat": chatObj{
		ID:       msg.ChatID,
		Name:     b.chatName(evt.Info.Chat),
		IsGroup:  evt.Info.IsGroup,
		LastTS:   msg.TS,
		LastText: previewOf(msg),
		Handles:  b.handlesFor(evt.Info.Chat),
		Tags:     tagsFor(evt.Info.Chat),
	}})
}

// onReceipt maps WhatsApp's delivery and read receipts onto the contract's
// status ladder. The host ratchets these, so an out-of-order receipt cannot
// move a message backwards.
func (b *bridge) onReceipt(evt *events.Receipt) {
	var status string
	switch evt.Type {
	case types.ReceiptTypeDelivered:
		status = "delivered"
	case types.ReceiptTypeRead, types.ReceiptTypeReadSelf:
		status = "read"
	default:
		// Played, retry and friends carry no meaning for the ladder.
		return
	}

	for _, id := range evt.MessageIDs {
		emitEvent("status", map[string]any{
			"messageId": string(id),
			"status":    status,
		})
	}

	// Read-self is this account reading somebody else's messages on another
	// device. A status on those messages changes nothing the host counts --
	// unread and notifications go by the conversation's read position -- so
	// the position is what has to move, or a conversation read on the phone
	// stays unread here and is announced anyway once the host catches up.
	if evt.Type == types.ReceiptTypeReadSelf {
		chatID := evt.Chat.String()
		upTo := b.newestUnread(chatID, evt.MessageIDs)
		if upTo == 0 && !evt.Timestamp.IsZero() {
			// Messages from before this bridge started are not remembered;
			// when the phone read them is the next best bound.
			upTo = evt.Timestamp.UnixMilli()
		}
		if upTo > 0 {
			b.readElsewhere(chatID, upTo)
		}
	}
}

// noteUnread remembers an incoming message until it is marked read.
func (b *bridge) noteUnread(chatID string, ref unreadRef) {
	b.mu.Lock()
	defer b.mu.Unlock()

	refs := append(b.unread[chatID], ref)
	if len(refs) > maxUnreadPerChat {
		refs = refs[len(refs)-maxUnreadPerChat:]
	}
	b.unread[chatID] = refs
}

// takeUnread removes and returns a conversation's remembered messages at or
// before upTo. Later ones stay: they arrived after whatever was read.
func (b *bridge) takeUnread(chatID string, upTo int64) []unreadRef {
	b.mu.Lock()
	defer b.mu.Unlock()

	var taken, kept []unreadRef
	for _, ref := range b.unread[chatID] {
		if ref.ts <= upTo {
			taken = append(taken, ref)
		} else {
			kept = append(kept, ref)
		}
	}
	if len(kept) == 0 {
		delete(b.unread, chatID)
	} else {
		b.unread[chatID] = kept
	}
	return taken
}

// newestUnread is the newest of the given messages still remembered as unread
// in a conversation, or zero if none of them is.
func (b *bridge) newestUnread(chatID string, ids []types.MessageID) int64 {
	b.mu.RLock()
	defer b.mu.RUnlock()

	var newest int64
	for _, ref := range b.unread[chatID] {
		if ref.ts > newest && slices.Contains(ids, ref.id) {
			newest = ref.ts
		}
	}
	return newest
}

// readElsewhere passes on that a conversation was read on another device.
//
// What was read there needs no receipt from here -- the phone sent its own --
// so it is forgotten as well.
func (b *bridge) readElsewhere(chatID string, upTo int64) {
	b.takeUnread(chatID, upTo)
	emitEvent("chat", map[string]any{"chat": chatObj{ID: chatID, ReadUpTo: upTo}})
}

// onHistorySync replays the backfill WhatsApp pushes after linking.
//
// Sent as batches: the host stores a batch in one transaction and does not
// notify for its contents, which is what stops a first login from firing
// hundreds of notifications.
func (b *bridge) onHistorySync(evt *events.HistorySync) {
	// Backfill is a lot of data for an account with years of history, and some
	// people would rather start clean.
	if !b.settingBool("syncHistory", true) {
		return
	}

	conversations := evt.Data.GetConversations()
	if len(conversations) == 0 {
		return
	}

	emitEvent("sync", map[string]any{"done": 0, "total": len(conversations)})

	var chats []chatObj
	var messages []messageObj

	for i, conv := range conversations {
		jid, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		if !isRelevantChat(jid) {
			continue
		}

		unread := int(conv.GetUnreadCount())
		chat := chatObj{
			ID:       jid.String(),
			Name:     conv.GetName(),
			IsGroup:  jid.Server == types.GroupServer,
			Archived: conv.GetArchived(),
			Unread:   &unread,
			Handles:  b.handlesFor(jid),
			Tags:     tagsFor(jid),
		}
		if chat.Name == "" {
			chat.Name = b.chatName(jid)
		}

		// Incoming messages that count as unread, for working out how far
		// the conversation had been read. "unsupported" is left out: whether
		// WhatsApp counted one is unknown, and guessing it did could place the
		// read position past a message that is still unread.
		var incoming []int64
		for _, histMsg := range conv.GetMessages() {
			msg := b.convertWebMessage(jid, histMsg.GetMessage())
			if msg == nil {
				continue
			}
			messages = append(messages, *msg)

			if msg.TS > chat.LastTS {
				chat.LastTS = msg.TS
				chat.LastText = previewOf(msg)
			}
			if !msg.FromMe && msg.Kind != "unsupported" {
				incoming = append(incoming, msg.TS)
			}
		}
		chat.ReadUpTo = historyReadUpTo(incoming, chat.LastTS, unread)

		chats = append(chats, chat)

		// Flush periodically so a very large sync appears progressively rather
		// than arriving as one enormous frame at the end.
		if len(messages) >= 500 {
			emitEvent("messages", map[string]any{"messages": messages})
			messages = nil
			emitEvent("sync", map[string]any{"done": i + 1, "total": len(conversations)})
		}
	}

	// Messages before the conversations they belong to: each conversation
	// carries its read position, which the host applies by recounting unread
	// from the messages it holds -- so they have to be there to be counted.
	if len(messages) > 0 {
		emitEvent("messages", map[string]any{"messages": messages})
	}
	if len(chats) > 0 {
		emitEvent("chats", map[string]any{"chats": chats})
	}

	emitEvent("sync", map[string]any{"done": len(conversations), "total": len(conversations)})
}

// historyReadUpTo is how far a backfilled conversation had been read, worked
// out from the unread count WhatsApp sends with it -- or zero, for no opinion.
//
// Without it a first link gave the host no read position for anything it
// brought in, and every incoming message in every conversation's history was
// counted as unread. The count says how many of the newest incoming messages
// are unread, so everything before the oldest of those has been read.
//
// A sync usually carries only part of a conversation, so the answer is bounded
// by what this batch holds, and early is the safe side to be wrong on: the host
// keeps the later of this and what it already has, so a position too early
// changes nothing, where one too late would hide a message that is unread.
func historyReadUpTo(incoming []int64, newest int64, unread int) int64 {
	if unread <= 0 {
		return newest
	}
	if len(incoming) < unread {
		// The batch does not reach back as far as the oldest unread message.
		return 0
	}

	sorted := slices.Clone(incoming)
	slices.Sort(sorted)
	oldestUnread := sorted[len(sorted)-unread]
	if oldestUnread <= 0 {
		return 0
	}
	return oldestUnread - 1
}

// syncChats publishes what the session already knows on connect: the groups it
// belongs to, and every contact with the number they can be found by.
//
// Without this, a conversation only becomes searchable once a message arrives
// in it -- so an account with years of history would appear almost empty, and
// searching a phone number would find nothing at all.
func (b *bridge) syncChats(ctx context.Context) {
	client := b.getClient()
	if client == nil {
		return
	}

	var chats []chatObj

	if groups, err := client.GetJoinedGroups(ctx); err == nil {
		// One request answers for every group, so it fills the name cache
		// that messages are labelled from.
		b.mu.Lock()
		for _, group := range groups {
			if group.Name != "" {
				b.groupNames[group.JID] = group.Name
			}
		}
		b.mu.Unlock()

		for _, group := range groups {
			chats = append(chats, chatObj{
				ID:      group.JID.String(),
				Name:    group.Name,
				IsGroup: true,
				Tags:    tagsFor(group.JID),
			})
		}
	} else {
		logf("debug", "could not list groups: %v", err)
	}

	chats = append(chats, b.contactChats(ctx)...)

	// Batched: an address book runs to thousands, and the host stores a batch
	// in one transaction.
	const batchSize = 500
	for start := 0; start < len(chats); start += batchSize {
		end := start + batchSize
		if end > len(chats) {
			end = len(chats)
		}
		emitEvent("chats", map[string]any{"chats": chats[start:end]})
	}

	if len(chats) > 0 {
		logf("info", "published %d known conversations", len(chats))
	}
}

// contactChats turns the address book into conversations that can be found
// before anyone has written in them.
//
// Carries no timestamp on purpose: these are contacts, not activity, and the
// host keeps them out of the conversation list until a message arrives.
func (b *bridge) contactChats(ctx context.Context) []chatObj {
	client := b.getClient()
	if client == nil || client.Store == nil || client.Store.Contacts == nil {
		return nil
	}

	contacts, err := client.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		logf("debug", "could not list contacts: %v", err)
		return nil
	}

	out := make([]chatObj, 0, len(contacts))
	for jid, info := range contacts {
		if !isRelevantChat(jid) || jid.Server == types.GroupServer {
			continue
		}

		name := contactDisplayName(info)
		handles := b.handlesFor(jid)
		// Nothing to contribute: no name to search for and no number to match.
		if name == "" && len(handles) == 0 {
			continue
		}

		out = append(out, chatObj{
			ID:      jid.String(),
			Name:    name,
			Handles: handles,
			Tags:    tagsFor(jid),
		})
	}
	return out
}

// isRelevantChat rejects only addresses that are not conversations at all.
//
// Newsletters and broadcast lists used to be dropped here, which meant a user
// who wanted them had no way to get them back. They are tagged instead, and
// filtered in the shell where the choice belongs.
func isRelevantChat(jid types.JID) bool {
	return !jid.IsEmpty()
}

// previewOf is the chat-list line for a message.
func previewOf(msg *messageObj) string {
	if msg.Text != "" {
		return msg.Text
	}
	if p := placeholderFor(msg.Kind); p != "" {
		return p
	}
	if msg.FileName != "" {
		return msg.FileName
	}
	return ""
}

func placeholderFor(kind string) string {
	switch kind {
	case "image":
		return "📷 Photo"
	case "video":
		return "🎥 Video"
	case "audio":
		return "🎤 Voice message"
	case "document":
		return "📄 Document"
	case "sticker":
		return "🌟 Sticker"
	case "location":
		return "📍 Location"
	case "contact":
		return "👤 Contact"
	case "deleted":
		return "🚫 Deleted message"
	}
	return ""
}

func tsMillis(t time.Time) int64 {
	if t.IsZero() {
		return time.Now().UnixMilli()
	}
	return t.UnixMilli()
}
