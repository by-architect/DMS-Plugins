package main

import (
	"context"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// handleWhatsAppEvent is the whole inbound path: whatsmeow events in, contract
// events out. Everything WhatsApp-shaped stops here.
func (b *bridge) handleWhatsAppEvent(evt any) {
	switch v := evt.(type) {

	case *events.Connected:
		emitState("connected")
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

	case *events.Message:
		b.onMessage(v)

	case *events.Receipt:
		b.onReceipt(v)

	case *events.HistorySync:
		b.onHistorySync(v)

	case *events.OfflineSyncCompleted:
		// The catch-up burst is over; the host can stop showing progress.
		emitEvent("sync", map[string]any{"done": 0, "total": 0})
	}
}

// onMessage converts a single incoming or echoed message.
func (b *bridge) onMessage(evt *events.Message) {
	msg := b.convertLive(evt.Info, evt.Message)
	if msg == nil {
		return
	}

	emitEvent("message", map[string]any{"message": msg})

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
		}

		chats = append(chats, chat)

		// Flush periodically so a very large sync appears progressively rather
		// than arriving as one enormous frame at the end.
		if len(messages) >= 500 {
			emitEvent("messages", map[string]any{"messages": messages})
			messages = nil
			emitEvent("sync", map[string]any{"done": i + 1, "total": len(conversations)})
		}
	}

	if len(chats) > 0 {
		emitEvent("chats", map[string]any{"chats": chats})
	}
	if len(messages) > 0 {
		emitEvent("messages", map[string]any{"messages": messages})
	}

	emitEvent("sync", map[string]any{"done": len(conversations), "total": len(conversations)})
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
