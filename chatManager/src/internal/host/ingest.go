package host

import (
	"context"
	"time"

	"dmschatmanager/internal/chat"
	"dmschatmanager/internal/log"
)

// ingestLoop is the single writer into the store.
//
// Everything a bridge reports funnels through here, which is what lets the
// bridges themselves stay stateless: they never open the database, so they
// cannot race each other or corrupt it.
func (m *Manager) ingestLoop() {
	defer m.wg.Done()

	for {
		select {
		case <-m.stopChan:
			return
		case ev := <-m.events:
			m.ingest(ev)
		}
	}
}

func (m *Manager) ingest(ev ingestEvent) {
	// A barrier: everything queued ahead of it has been stored once it is
	// reached, which is what a caller waiting on a bridge's answer needs to
	// know before it reads the store again. See drainIngest.
	if ev.barrier != nil {
		close(ev.barrier)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	switch ev.frame.Event {
	case EventChat:
		if ev.frame.Chat != nil {
			m.ingestChats(ctx, ev.provider, []wireChat{*ev.frame.Chat})
		}

	case EventChats:
		m.ingestChats(ctx, ev.provider, ev.frame.Chats)

	case EventMessage:
		if ev.frame.Message != nil {
			m.ingestMessages(ctx, ev.provider, []wireMessage{*ev.frame.Message}, true, false)
		}

	case EventMessages:
		// A batch is backfill: store it, but do not notify for each entry. One
		// marked as backfill is older history fetched on request, which is not
		// counted as unread either.
		m.ingestMessages(ctx, ev.provider, ev.frame.Messages, false, ev.frame.Backfill)

	case EventReaction:
		if ev.frame.Reaction != nil {
			m.ingestReactions(ctx, ev.provider, []wireReaction{*ev.frame.Reaction})
		}

	case EventReactions:
		m.ingestReactions(ctx, ev.provider, ev.frame.Reactions)

	case EventTyping:
		// Nothing to store and nothing to redraw: it goes straight to whoever
		// is watching, and is stale within seconds anyway.
		m.relayTyping(ev.provider, ev.frame.ChatID, ev.frame.Users)
		return

	case EventStatus:
		if ev.frame.MessageID == "" || ev.frame.Status == "" {
			return
		}
		if err := m.store.SetMessageStatus(ctx, ev.provider, ev.frame.MessageID, ev.frame.Status); err != nil {
			log.Warnf("chat: status update failed for %s/%s: %v", ev.provider, ev.frame.MessageID, err)
			return
		}

	case EventChatGone:
		if ev.frame.ChatID == "" {
			return
		}
		if err := m.store.DeleteChatIfUnwritten(ctx, ev.provider, ev.frame.ChatID); err != nil {
			log.Warnf("chat: could not remove %s/%s: %v", ev.provider, ev.frame.ChatID, err)
			return
		}

	case EventDeleted:
		if ev.frame.MessageID == "" {
			return
		}
		if err := m.store.MarkDeleted(ctx, ev.provider, ev.frame.ChatID, ev.frame.MessageID); err != nil {
			log.Warnf("chat: delete failed for %s/%s: %v", ev.provider, ev.frame.MessageID, err)
			return
		}

	case EventSync:
		m.mu.Lock()
		if ev.frame.Total > 0 && ev.frame.Done < ev.frame.Total {
			m.sync[ev.provider] = SyncProgress{Done: ev.frame.Done, Total: ev.frame.Total}
		} else {
			delete(m.sync, ev.provider)
		}
		m.mu.Unlock()

	case EventState:
		// State and capabilities live on the bridge; a broadcast is all the
		// UI needs. Here it means something else as well: connecting is a
		// provider about to replay what we missed, and connected is the point
		// at which what it replayed can be judged. See settle.go.
		m.noteProviderState(ev.provider, ev.frame.State)

	case EventReady, EventAuth, EventAccount:
		// Nothing to store; the broadcast below is what the UI re-reads.

	default:
		return
	}

	m.markDirty()
}

func (m *Manager) ingestChats(ctx context.Context, provider string, chats []wireChat) {
	for _, wc := range chats {
		if wc.ID == "" {
			continue
		}

		c := chat.Chat{
			Provider:     provider,
			ID:           wc.ID,
			Name:         wc.Name,
			IsGroup:      wc.IsGroup,
			LastTS:       wc.LastTS,
			LastText:     wc.LastText,
			AvatarPath:   wc.AvatarPath,
			Subject:      wc.Subject,
			Participants: wc.Participants,
			Folder:       wc.Folder,
			Handles:      wc.Handles,
			Tags:         wc.Tags,
		}

		// A bridge that did not mention unread must not clear a count the host
		// derived from the messages themselves.
		c.Unread = -1
		if wc.Unread != nil {
			c.Unread = *wc.Unread
		}

		if err := m.store.UpsertChat(ctx, c); err != nil {
			log.Warnf("chat: failed to store chat %s/%s: %v", provider, wc.ID, err)
			continue
		}

		// Where the provider says this conversation has been read, which it
		// may know better than we do: read on a phone, in another client. The
		// store takes the later of the two and recounts unread from the
		// messages themselves, so this can only ever settle a disagreement in
		// the direction of "already seen".
		if wc.ReadUpTo > 0 {
			if err := m.store.SetReadUpTo(ctx, provider, wc.ID, wc.ReadUpTo); err != nil {
				log.Warnf("chat: failed to set read position on %s/%s: %v", provider, wc.ID, err)
			}
		}

		// Only when the bridge actually stated them, so a partial update does
		// not quietly undo what the user chose.
		if wc.Archived != nil {
			if err := m.store.SetArchived(ctx, provider, wc.ID, *wc.Archived); err != nil {
				log.Warnf("chat: failed to set archived on %s/%s: %v", provider, wc.ID, err)
			}
		}
		if wc.Muted != nil {
			if err := m.store.SetMuted(ctx, provider, wc.ID, *wc.Muted); err != nil {
				log.Warnf("chat: failed to set muted on %s/%s: %v", provider, wc.ID, err)
			}
		}
	}
}

// ingestMessages stores messages and, for live ones, decides whether to notify.
//
// backfill is older history a bridge fetched because it was asked to: nothing
// in it is waiting on anyone, so none of it counts as unread, whatever the
// conversation's read position says.
func (m *Manager) ingestMessages(ctx context.Context, provider string, msgs []wireMessage, live, backfill bool) {
	if len(msgs) == 0 {
		return
	}

	stored := make([]chat.Message, 0, len(msgs))
	for _, wm := range msgs {
		if wm.ID == "" || wm.ChatID == "" {
			log.Warnf("chat: %s sent a message with no id or chat id", provider)
			continue
		}
		stored = append(stored, m.materialize(provider, wm))
	}
	if len(stored) == 0 {
		return
	}

	// One transaction for the batch: a history sync arrives in thousands, and
	// a transaction per message turns a first login into minutes of fsync.
	fresh, err := m.store.InsertMessages(ctx, stored)
	if err != nil {
		log.Warnf("chat: failed to store %d message(s) from %s: %v", len(stored), provider, err)
		return
	}

	for i, msg := range stored {
		// Only a message the store had never seen is news. Bridges redeliver
		// -- a reconnect replays the last few messages, a sync resends what
		// came in live -- and counting each copy put a conversation's badge
		// at twice what was waiting, and announced the same message again.
		isNew := fresh[i]

		// Keep the chat's activity line in step with its newest message, and
		// create the chat if the bridge never announced it.
		incrementUnread := isNew && !msg.FromMe && !isProtocol(msg.Kind) && !backfill
		if err := m.store.TouchChat(ctx, provider, msg.ChatID, "", msg.Preview(), msg.TS, false, incrementUnread); err != nil {
			log.Warnf("chat: failed to touch chat %s/%s: %v", provider, msg.ChatID, err)
		}

		if !live || !isNew {
			continue
		}
		// The service's own settings say this one should not interrupt
		// anyone -- a room set to mentions only, say. It is stored and counted
		// like any other; it just does not notify, now or after a catch-up.
		if msg.Silent {
			continue
		}
		// While the provider is still catching up this is put aside rather
		// than announced -- it may well have been read elsewhere already, and
		// we will know shortly.
		if m.holdNotification(provider, msg) {
			continue
		}
		m.notify.Notify(ctx, msg, m.providerName(provider), m.ProviderPrefs(provider))
	}
}

// materialize turns a wire message into a stored one, resolving its media.
func (m *Manager) materialize(provider string, wm wireMessage) chat.Message {
	msg := chat.Message{
		Provider:         provider,
		ChatID:           wm.ChatID,
		ID:               wm.ID,
		TS:               wm.TS,
		FromMe:           wm.FromMe,
		SenderID:         wm.SenderID,
		SenderName:       wm.SenderName,
		SenderAvatarPath: wm.SenderAvatarPath,
		Kind:             wm.Kind,
		Text:             wm.Text,
		BodyHTML:         wm.BodyHTML,
		Status:           wm.Status,
		ReplyTo:          wm.ReplyTo,
		CC:               wm.CC,
		BCC:              wm.BCC,
		MediaRef:         wm.MediaRef,
		MediaMime:        wm.MediaMime,
		MediaW:           wm.MediaW,
		MediaH:           wm.MediaH,
		FileName:         wm.FileName,
		FileSize:         wm.FileSize,
		Duration:         wm.Duration,
		EditedTS:         wm.EditedTS,
		LinkURL:          wm.LinkURL,
		LinkTitle:        wm.LinkTitle,
		LinkDesc:         wm.LinkDesc,
		LinkImage:        wm.LinkImage,
		Silent:           wm.Silent,
		Highlight:        wm.Highlight,
	}

	if msg.TS == 0 {
		msg.TS = time.Now().UnixMilli()
	}

	// Media resolution is best-effort: a message with a broken attachment is
	// still worth storing, since its text and place in the conversation matter.
	switch {
	case wm.MediaPath != "":
		path, err := m.media.Adopt(provider, wm.ID, wm.MediaMime, wm.MediaPath)
		if err != nil {
			log.Warnf("chat: could not adopt media for %s/%s: %v", provider, wm.ID, err)
			break
		}
		msg.MediaPath = path

	case wm.MediaBytes != "":
		path, err := m.media.StoreBase64(provider, wm.ID, wm.MediaMime, wm.MediaBytes)
		if err != nil {
			log.Warnf("chat: could not store inline media for %s/%s: %v", provider, wm.ID, err)
			break
		}
		msg.MediaPath = path
	}

	return msg
}

// ingestReactions stores reactions as a bridge reported them.
func (m *Manager) ingestReactions(ctx context.Context, provider string, reactions []wireReaction) {
	stored := make([]chat.Reaction, 0, len(reactions))
	for _, wr := range reactions {
		if wr.ID == "" || wr.ChatID == "" || wr.MessageID == "" || wr.Key == "" {
			continue
		}
		stored = append(stored, chat.Reaction{
			Provider:   provider,
			ChatID:     wr.ChatID,
			ID:         wr.ID,
			MessageID:  wr.MessageID,
			Key:        wr.Key,
			SenderID:   wr.SenderID,
			SenderName: wr.SenderName,
			FromMe:     wr.FromMe,
			TS:         wr.TS,
		})
	}
	if err := m.store.PutReactions(ctx, stored); err != nil {
		log.Warnf("chat: failed to store %d reaction(s) from %s: %v", len(stored), provider, err)
	}
}

func (m *Manager) providerName(providerID string) string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if p, ok := m.providers[providerID]; ok {
		return p.Name
	}
	return providerID
}

// isProtocol mirrors the store's notion of a bookkeeping row. Protocol rows are
// not unread messages, so a channel full of join events wears no badge.
func isProtocol(kind string) bool {
	switch kind {
	case chat.KindSystem, chat.KindDeleted, chat.KindUnsupported:
		return true
	}
	return false
}
