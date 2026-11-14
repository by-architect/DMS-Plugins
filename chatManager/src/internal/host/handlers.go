package host

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"dmschatmanager/internal/chat"
	"dmschatmanager/internal/log"
	"dmschatmanager/internal/models"
)

// requestTimeout bounds a single shell request. Bridge calls have their own,
// longer budget; this is the ceiling on the whole round trip.
const requestTimeout = 30 * time.Second

// HandleRequest dispatches a chat.* method.
func HandleRequest(conn *models.Conn, req models.Request, manager *Manager) {
	if manager == nil {
		models.RespondError(conn, req.ID, "chat manager not initialized")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()

	switch req.Method {
	case "chat.providers":
		handleProviders(ctx, conn, req, manager)
	case "chat.rescan":
		handleRescan(ctx, conn, req, manager)
	case "chat.setEnabled":
		handleSetEnabled(ctx, conn, req, manager)
	case "chat.setProviderSettings":
		handleSetProviderSettings(conn, req, manager)
	case "chat.setConfig":
		handleSetConfig(conn, req, manager)
	case "chat.setProviderConfig":
		handleSetProviderConfig(conn, req, manager)
	case "chat.getConfig":
		models.Respond(conn, req.ID, manager.GetConfig())

	case "chat.chats":
		handleChats(ctx, conn, req, manager)
	case "chat.history":
		handleHistory(ctx, conn, req, manager)
	case "chat.send":
		handleSend(ctx, conn, req, manager)
	case "chat.markRead":
		handleMarkRead(ctx, conn, req, manager)
	case "chat.setFocus":
		handleSetFocus(conn, req, manager)
	case "chat.fetchMedia":
		handleFetchMedia(ctx, conn, req, manager)
	case "chat.unread":
		handleUnread(ctx, conn, req, manager)
	case "chat.tags":
		handleTags(ctx, conn, req, manager)
	case "chat.resolve":
		handleResolve(ctx, conn, req, manager)
	case "chat.search":
		handleSearch(ctx, conn, req, manager)
	case "chat.setArchived":
		handleSetFlag(ctx, conn, req, manager, "archived")
	case "chat.setMuted":
		handleSetFlag(ctx, conn, req, manager, "muted")
	case "chat.login":
		handleAuth(ctx, conn, req, manager, MethodLogin)
	case "chat.logout":
		handleAuth(ctx, conn, req, manager, MethodLogout)
	case "chat.revoke":
		handleRevoke(ctx, conn, req, manager)
	case "chat.acceptInvite":
		handleInvite(ctx, conn, req, manager, true)
	case "chat.declineInvite":
		handleInvite(ctx, conn, req, manager, false)
	case "chat.react":
		handleReact(ctx, conn, req, manager, false)
	case "chat.unreact":
		handleReact(ctx, conn, req, manager, true)
	case "chat.edit":
		handleEdit(ctx, conn, req, manager)
	case "chat.typing":
		handleTyping(conn, req, manager)
	case "chat.startChat":
		handleStartChat(ctx, conn, req, manager)
	case "chat.members":
		handleMembers(ctx, conn, req, manager)
	case "chat.deleteLocal":
		handleDeleteLocal(ctx, conn, req, manager)
	case "chat.purge":
		handlePurge(ctx, conn, req, manager)
	case "chat.authQrCode":
		handleAuthQRCode(conn, req, manager)
	case "chat.authSubmit":
		handleAuthSubmit(ctx, conn, req, manager)
	case "chat.tap":
		// Streams until the client disconnects, so it must not run under the
		// request timeout the other methods share.
		handleTap(conn, req, manager)

	default:
		models.RespondError(conn, req.ID, fmt.Sprintf("unknown method: %s", req.Method))
	}
}

// ---------------------------------------------------------------- providers

type providersResult struct {
	Providers []ProviderStatus `json:"providers"`
}

func handleProviders(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	models.Respond(conn, req.ID, providersResult{Providers: m.Providers(ctx)})
}

func handleRescan(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	m.Rescan()
	models.Respond(conn, req.ID, providersResult{Providers: m.Providers(ctx)})
}

func handleSetEnabled(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, ok := models.Get[string](req, "provider")
	if !ok || provider == "" {
		models.RespondError(conn, req.ID, "provider is required")
		return
	}
	enabled := models.GetOr(req, "enabled", true)
	settings, _ := models.Get[map[string]any](req, "settings")

	if err := m.SetEnabled(ctx, provider, enabled, settings); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

func handleSetProviderSettings(conn *models.Conn, req models.Request, m *Manager) {
	provider, ok := models.Get[string](req, "provider")
	if !ok || provider == "" {
		models.RespondError(conn, req.ID, "provider is required")
		return
	}
	settings, ok := models.Get[map[string]any](req, "settings")
	if !ok {
		models.RespondError(conn, req.ID, "settings is required")
		return
	}

	if err := m.SetProviderSettings(provider, settings); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	log.Debugf("chat: reconfigured %s with %s", provider, settingsJSON(settings))
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

func handleSetConfig(conn *models.Conn, req models.Request, m *Manager) {
	raw, err := json.Marshal(req.Params)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	// Start from the current config so a partial update does not reset
	// everything the caller left out.
	cfg := m.GetConfig()
	if err := json.Unmarshal(raw, &cfg); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	m.SetConfig(cfg)
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleSetProviderConfig overrides the notification policy for one provider.
func handleSetProviderConfig(conn *models.Conn, req models.Request, m *Manager) {
	provider, ok := models.Get[string](req, "provider")
	if !ok || provider == "" {
		models.RespondError(conn, req.ID, "provider is required")
		return
	}

	// Start from the provider's effective policy, so a partial update changes
	// only what the caller named.
	prefs := m.ProviderPrefs(provider)
	prefs.Enabled = models.GetOr(req, "notificationsEnabled", prefs.Enabled)
	prefs.Preview = models.GetOr(req, "notificationPreview", prefs.Preview)
	prefs.Groups = models.GetOr(req, "notifyGroups", prefs.Groups)
	prefs.Archived = models.GetOr(req, "notifyArchived", prefs.Archived)
	prefs.DoNotDisturb = models.GetOr(req, "doNotDisturb", prefs.DoNotDisturb)

	// Replaced wholesale rather than merged: the caller sends the complete list
	// it wants, and a merge would make removing a tag impossible.
	if raw, ok := models.Get[[]any](req, "mutedTags"); ok {
		tags := make([]string, 0, len(raw))
		for _, item := range raw {
			if tag, ok := item.(string); ok && tag != "" {
				tags = append(tags, tag)
			}
		}
		prefs.MutedTags = tags
	}

	m.SetProviderPrefs(provider, prefs)
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// ---------------------------------------------------------------- reads

type chatsResult struct {
	Chats []chat.Chat `json:"chats"`
}

func handleChats(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	limit := models.GetOr(req, "limit", 200)

	// "all" includes conversations a provider knows about but that have no
	// messages yet -- most of an address book. Wanted by a picker or runner,
	// not by the conversation list, which would otherwise be mostly people you
	// have never written to.
	all := models.GetOr(req, "all", false)

	var (
		chats []chat.Chat
		err   error
	)
	// Only providers that are switched on. Their conversations stay in the
	// store while a provider is off -- disabling a plugin must not throw away
	// history -- but they are not shown.
	visible := m.EnabledProviders()

	switch {
	case all:
		chats, err = m.Store().AllChatsIn(ctx, visible, limit)
	default:
		if provider, ok := models.Get[string](req, "provider"); ok && provider != "" {
			if !m.IsEnabled(provider) {
				models.Respond(conn, req.ID, chatsResult{Chats: []chat.Chat{}})
				return
			}
			chats, err = m.Store().ChatsForProvider(ctx, provider, limit)
		} else {
			chats, err = m.Store().ChatsIn(ctx, visible, limit)
		}
	}
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if chats == nil {
		chats = []chat.Chat{}
	}
	models.Respond(conn, req.ID, chatsResult{Chats: chats})
}

// historyResult is a page of a conversation, and where that conversation had
// been read when the page was asked for.
//
// The read position travels with the page rather than being looked up in the
// conversation list the shell holds: that list is only streamed while a chat
// window is open, so a conversation opened from the launcher would be judged
// against a cache that may be hours old -- and the unread divider would land in
// the wrong place, or not appear at all. Requests on one connection are answered
// in order, so this is still the position from before opening marked the
// conversation read.
type historyResult struct {
	Messages []chat.Message `json:"messages"`
	HasMore  bool           `json:"hasMore"`
	ReadUpTo int64          `json:"readUpTo"`
	Unread   int            `json:"unread"`
}

func handleHistory(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}

	before := int64(models.GetOr(req, "before", 0))
	limit := models.GetOr(req, "limit", 50)

	msgs, hasMore, err := m.Store().Page(ctx, provider, chatID, before, limit)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	b, bridgeErr := m.bridgeFor(provider)
	canFetch := bridgeErr == nil && b.HasCapability(CapHistory) && !m.HistoryEnded(provider, chatID)

	switch {
	case before > 0 && !hasMore && canFetch && len(msgs) < limit:
		// The store ran out short of what was asked, and the provider can look
		// further back: ask it, wait for what it finds to be stored, and page
		// again. Answered on a lane of its own (see laneFor), so the wait holds
		// up nothing else.
		from := before
		if len(msgs) > 0 {
			from = msgs[0].TS
		}
		more, err := m.fetchHistory(ctx, b, provider, chatID, from, limit-len(msgs))
		if err != nil {
			log.Warnf("chat: could not fetch older messages for %s/%s: %v", provider, chatID, err)
			// Still more, as far as anyone knows: the next scroll asks again.
			hasMore = true
			break
		}
		if again, againMore, err := m.Store().Page(ctx, provider, chatID, before, limit); err == nil {
			msgs, hasMore = again, againMore
		}
		hasMore = hasMore || more

	case !hasMore && canFetch:
		// Everything stored fits in this page, and the provider can fetch what
		// is older. Saying there is more is what makes reaching the top of the
		// conversation ask for it, rather than stopping where this device
		// happened to start listening.
		hasMore = true

	case len(msgs) == 0 && before > 0 && bridgeErr == nil && !b.HasCapability(CapHistory):
		// A provider without the capability may still backfill: asked, it
		// answers by streaming message events, so this request returns what
		// there is now and the UI updates when they land.
		b.notify(MethodHistory, map[string]any{
			"chatId": chatID, "before": before, "limit": limit,
		})
	}

	if msgs == nil {
		msgs = []chat.Message{}
	}

	// Missing is not an error: a conversation can be paged before its own row
	// has been written, and a page without a read position is still a page.
	var readUpTo int64
	var unread int
	if c, err := m.Store().ChatByID(ctx, provider, chatID); err == nil {
		readUpTo = c.ReadUpTo
		unread = c.Unread
	}

	models.Respond(conn, req.ID, historyResult{
		Messages: msgs, HasMore: hasMore, ReadUpTo: readUpTo, Unread: unread,
	})
}

const (
	// historyBudget is how long one request waits on a provider for older
	// messages: under the request's own timeout, so the shell always hears
	// back, if only that there may be more.
	historyBudget = 25 * time.Second

	// historyRounds is how many times a provider is asked before an answer
	// with nothing older in it is handed back as it is.
	historyRounds = 3

	// historyMinimum is the least asked for at once. A page that came back
	// three short of full is still worth a page's round trip.
	historyMinimum = 20
)

// fetchHistory asks a provider for messages older than from, and waits until
// what it sent has been stored. Reports whether the provider says there is
// still more before that.
//
// A provider can answer with nothing older than from and still say there is
// more: a stretch of history that was all reactions, or room changes, or
// messages this device already had. That is asked again, a few times, rather
// than handed to the shell as an empty page claiming more -- which shows
// nothing new and leaves the reader nothing left to scroll to.
func (m *Manager) fetchHistory(ctx context.Context, b *bridge, provider, chatID string, from int64, limit int) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, historyBudget)
	defer cancel()

	if limit < historyMinimum {
		limit = historyMinimum
	}

	for round := 1; ; round++ {
		frame, err := b.call(ctx, MethodHistory, map[string]any{
			"chatId": chatID, "before": from, "limit": limit,
		})
		if err != nil {
			return true, err
		}

		var reply historyReply
		if len(frame.Result) > 0 {
			_ = json.Unmarshal(frame.Result, &reply)
		}
		m.drainIngest(ctx)

		// A provider that does not say has nothing more it can find: offering
		// to page further would only ask it the same question again.
		if reply.HasMore == nil || !*reply.HasMore {
			m.markHistoryEnded(provider, chatID)
			return false, nil
		}
		if round >= historyRounds || ctx.Err() != nil {
			return true, nil
		}
		if older, _, err := m.Store().Page(ctx, provider, chatID, from, 1); err == nil && len(older) > 0 {
			return true, nil
		}
	}
}

type searchResult struct {
	Messages []chat.SearchHit `json:"messages"`
	Chats    []chat.Chat      `json:"chats"`
}

// unreadResult is every conversation with something waiting in it, and the
// messages that are waiting.
type unreadResult struct {
	Chats    []chat.Chat      `json:"chats"`
	Messages []chat.SearchHit `json:"messages"`
}

// handleUnread answers "what have I not got to yet".
//
// Both halves, because they answer different questions: the conversations are
// what a cycle key steps through, and the messages are what a search over
// unread text matches on. Deriving one from the other in the caller would mean
// either fetching all messages or losing the text.
func handleUnread(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	limit := models.GetOr(req, "limit", 200)
	visible := m.EnabledProviders()

	chats, err := m.Store().ChatsIn(ctx, visible, 0)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	unread := make([]chat.Chat, 0, 8)
	for _, c := range chats {
		// Archived is how a user says "keep this out of my way", and a muted
		// conversation still counts: muting silences it, it does not mark it
		// read.
		if c.Unread > 0 && !c.Archived {
			unread = append(unread, c)
		}
	}

	msgs, err := m.Store().UnreadMessagesIn(ctx, visible, limit)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if msgs == nil {
		msgs = []chat.SearchHit{}
	}

	models.Respond(conn, req.ID, unreadResult{Chats: unread, Messages: msgs})
}

func handleSearch(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	query, ok := models.Get[string](req, "query")
	if !ok || query == "" {
		models.RespondError(conn, req.ID, "query is required")
		return
	}
	limit := models.GetOr(req, "limit", 50)

	// Inside one conversation: the search bar of an open conversation. Only
	// its own messages, from the store, and no conversations -- the provider
	// is not asked either, since a provider's search spans the whole account.
	provider := models.GetOr(req, "provider", "")
	chatID := models.GetOr(req, "chatId", "")
	if provider != "" && chatID != "" {
		msgs, err := m.Store().SearchChatMessages(ctx, provider, chatID, query, limit)
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		if msgs == nil {
			msgs = []chat.SearchHit{}
		}
		models.Respond(conn, req.ID, searchResult{Messages: msgs, Chats: []chat.Chat{}})
		return
	}

	visible := m.EnabledProviders()
	msgs, err := m.Store().SearchMessagesIn(ctx, visible, query, limit)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	chats, err := m.Store().SearchChatsIn(ctx, visible, query, limit)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	// Local search always works; providers that can search server-side are
	// asked as well, and their results arrive as message events.
	m.mu.RLock()
	bridges := make([]*bridge, 0, len(m.bridges))
	for _, b := range m.bridges {
		bridges = append(bridges, b)
	}
	m.mu.RUnlock()

	for _, b := range bridges {
		if b.HasCapability(CapSearch) {
			b.notify(MethodSearch, map[string]any{"query": query, "limit": limit})
		}
	}

	// Empty results are sent as [] rather than null: a nil Go slice encodes as
	// JSON null, which a caller doing `.length` on has to defend against.
	if msgs == nil {
		msgs = []chat.SearchHit{}
	}
	if chats == nil {
		chats = []chat.Chat{}
	}

	models.Respond(conn, req.ID, searchResult{Messages: msgs, Chats: chats})
}

type tagsResult struct {
	Tags []string `json:"tags"`
}

// handleTags lists every tag in use, so a filter offers what actually exists
// rather than a set the shell guessed at.
func handleTags(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	tags, err := m.Store().KnownTags(ctx)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if tags == nil {
		tags = []string{}
	}
	models.Respond(conn, req.ID, tagsResult{Tags: tags})
}

type resolveResult struct {
	Candidates []ResolveCandidate `json:"candidates"`
}

// handleResolve turns whatever identifier the caller has into conversations.
func handleResolve(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	query, ok := models.Get[string](req, "query")
	if !ok || query == "" {
		models.RespondError(conn, req.ID, "query is required")
		return
	}

	candidates := m.Resolve(ctx, query, models.GetOr(req, "limit", 10))
	if candidates == nil {
		candidates = []ResolveCandidate{}
	}
	models.Respond(conn, req.ID, resolveResult{Candidates: candidates})
}

// ---------------------------------------------------------------- writes

type sendResponse struct {
	Success   bool   `json:"success"`
	MessageID string `json:"messageId,omitempty"`
}

func handleSend(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}

	text := models.GetOr(req, "text", "")
	replyTo := models.GetOr(req, "replyTo", "")
	rawAttachments, _ := models.Get[[]any](req, "attachments")

	attachments := make([]string, 0, len(rawAttachments))
	for _, item := range rawAttachments {
		if path, ok := item.(string); ok && path != "" {
			attachments = append(attachments, path)
		}
	}

	if text == "" && len(attachments) == 0 {
		models.RespondError(conn, req.ID, "nothing to send")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if !b.HasCapability(CapSend) {
		models.RespondError(conn, req.ID, fmt.Sprintf("%s cannot send messages", provider))
		return
	}

	// No attachments: one message, the simple case.
	if len(attachments) == 0 {
		id, err := m.sendOne(ctx, b, provider, chatID, text, replyTo, "")
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, sendResponse{Success: true, MessageID: id})
		return
	}

	// One message per attachment, each with its own row.
	//
	// The provider sends them separately, so recording a single row would show
	// one message in the conversation while several actually went out. The
	// caption rides on the first, as it does in other clients.
	var lastID string
	for i, path := range attachments {
		caption := ""
		if i == 0 {
			caption = text
		}

		// Only the first carries the reply, so a batch does not quote the same
		// message several times over.
		reply := ""
		if i == 0 {
			reply = replyTo
		}

		id, err := m.sendOne(ctx, b, provider, chatID, caption, reply, path)
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		lastID = id
	}

	models.Respond(conn, req.ID, sendResponse{Success: true, MessageID: lastID})
}

// sendOne records a message, hands it to the bridge, and reconciles the row
// with whatever id the provider assigned.
//
// A pending row goes in first so the message appears in the conversation
// immediately rather than after the network round trip.
func (m *Manager) sendOne(ctx context.Context, b *bridge, provider, chatID, text, replyTo, attachment string) (string, error) {
	pendingID := fmt.Sprintf("pending-%d", time.Now().UnixNano())
	now := time.Now().UnixMilli()

	pending := chat.Message{
		Provider: provider, ChatID: chatID, ID: pendingID, TS: now,
		FromMe: true, Kind: chat.KindText, Text: text,
		Status: chat.StatusPending, ReplyTo: replyTo,
	}

	// Record the attachment ourselves rather than waiting for the provider to
	// echo it back. The user picked a local file, so there is nothing to
	// download -- and without this, a photo you sent shows as a bare caption
	// while the same photo received from someone else renders fine.
	if attachment != "" {
		mime := chat.MimeForPath(attachment)
		if cached, err := m.Media().Adopt(provider, pendingID, mime, attachment); err == nil {
			pending.MediaPath = cached
			pending.MediaMime = mime
			pending.Kind = chat.KindForPath(attachment)
			pending.FileName = filepath.Base(attachment)
		} else {
			log.Warnf("chat: could not cache the sent attachment: %v", err)
		}
	}

	if err := m.Store().PutMessage(ctx, pending); err != nil {
		log.Warnf("chat: could not record pending message: %v", err)
	}
	_ = m.Store().TouchChat(ctx, provider, chatID, "", pending.Preview(), now, false, false)
	m.markDirty()

	params := map[string]any{"chatId": chatID}
	if text != "" {
		params["text"] = text
	}
	if attachment != "" {
		params["attachments"] = []string{attachment}
	}
	if replyTo != "" {
		params["replyTo"] = replyTo

		// A reply has to quote what it is replying to, and only the store knows
		// that. Without it a provider builds a reply quoting an empty message,
		// which is what the recipient then sees.
		if quoted, err := m.Store().MessageByID(ctx, provider, chatID, replyTo); err == nil {
			params["replyToText"] = quoted.Text
			params["replyToSender"] = quoted.SenderID
			params["replyToFromMe"] = quoted.FromMe
			params["replyToKind"] = quoted.Kind
		} else {
			log.Warnf("chat: replying to a message that is not stored: %v", err)
		}
	}

	frame, err := b.call(ctx, MethodSend, params)
	if err != nil {
		// Leave the row in place, marked failed, so the user can see what did
		// not go out rather than having it silently vanish.
		_ = m.Store().SetMessageStatus(ctx, provider, pendingID, chat.StatusFailed)
		m.markDirty()
		return "", err
	}

	messageID := pendingID
	if len(frame.Result) > 0 {
		var res sendResult
		if err := json.Unmarshal(frame.Result, &res); err == nil && res.MessageID != "" {
			messageID = res.MessageID
		}
	}

	// The bridge assigned a real id: replace the placeholder rather than
	// leaving a duplicate behind when the message is echoed back.
	if messageID != pendingID {
		if err := m.Store().DeleteMessage(ctx, provider, chatID, pendingID); err != nil {
			log.Warnf("chat: could not clear pending message: %v", err)
		}

		sent := pending
		sent.ID = messageID
		sent.Status = chat.StatusSent

		// The cached file is named after the placeholder id, so move it to the
		// real one; otherwise the next cache sweep sees it as unreferenced.
		if sent.MediaPath != "" {
			if moved, err := m.Media().Rename(provider, pendingID, messageID, sent.MediaPath); err == nil {
				sent.MediaPath = moved
			}
		}

		if err := m.Store().PutMessage(ctx, sent); err != nil {
			log.Warnf("chat: could not record sent message: %v", err)
		}
	} else {
		_ = m.Store().SetMessageStatus(ctx, provider, pendingID, chat.StatusSent)
	}

	m.markDirty()
	return messageID, nil
}

// markReadLimit caps how many messages one markRead itemises for a bridge.
// Newest first, so what goes without a receipt past it is the oldest -- the
// part of a conversation left for months that nobody is waiting on a tick for
// -- and opening it does not turn into thousands of receipts at once.
const markReadLimit = 300

func handleMarkRead(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}

	upTo := int64(models.GetOr(req, "upTo", 0))
	if upTo <= 0 {
		upTo = time.Now().UnixMilli()
	}

	b, err := m.bridgeFor(provider)
	upstream := err == nil && b.HasCapability(CapMarkRead)

	params := map[string]any{"chatId": chatID, "upTo": upTo}
	if upstream {
		// The messages this makes read, itemised. WhatsApp and Signal receipt
		// a message by its id and sender, not a point in time, and a bridge
		// only remembers what arrived while it was running -- so after a
		// restart, reading older messages here told nobody. Listed before the
		// read position moves, since afterwards nothing tells them apart from
		// messages read long ago. If the list cannot be had the bridge still
		// gets upTo, and makes do with what it remembers.
		if reading, err := m.Store().UnreadUpTo(ctx, provider, chatID, upTo, markReadLimit); err == nil {
			refs := make([]map[string]any, 0, len(reading))
			for _, msg := range reading {
				refs = append(refs, map[string]any{"id": msg.ID, "senderId": msg.SenderID, "ts": msg.TS})
			}
			params["messages"] = refs
		} else {
			log.Warnf("chat: could not list the messages being read: %v", err)
		}
	}

	if err := m.Store().SetReadUpTo(ctx, provider, chatID, upTo); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	// Best effort upstream: the local badge is cleared regardless, since a
	// provider that cannot post a read receipt should not leave a stuck count.
	if upstream {
		b.notify(MethodMarkRead, params)
	}

	m.markDirty()
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleSetFocus records which chat is on screen, so a message the user is
// already looking at does not also raise a notification.
func handleSetFocus(conn *models.Conn, req models.Request, m *Manager) {
	provider := models.GetOr(req, "provider", "")
	chatID := models.GetOr(req, "chatId", "")

	m.Notify().SetFocus(provider, chatID)
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

func handleSetFlag(ctx context.Context, conn *models.Conn, req models.Request, m *Manager, flag string) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}
	value := models.GetOr(req, "value", true)

	var err error
	if flag == "archived" {
		err = m.Store().SetArchived(ctx, provider, chatID, value)
	} else {
		err = m.Store().SetMuted(ctx, provider, chatID, value)
	}
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	// A service that keeps its own notification settings is told too, so the
	// conversation is quiet on the user's phone as well as here. Best effort:
	// the mute here stands either way.
	if flag == "muted" {
		if b, err := m.bridgeFor(provider); err == nil && b.HasCapability(CapMute) {
			b.notify(MethodSetMuted, map[string]any{"chatId": chatID, "muted": value})
		}
	}

	m.markDirty()
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleReact adds a reaction to a message, or with remove takes ours back.
//
// Toggling is the shell's to decide -- it knows whether the key it shows is
// ours -- so both directions are explicit here, and asking for what is already
// so is a success rather than a second reaction or a failed removal.
func handleReact(ctx context.Context, conn *models.Conn, req models.Request, m *Manager, remove bool) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}
	messageID := models.GetOr(req, "messageId", "")
	key := models.GetOr(req, "key", "")
	if messageID == "" || key == "" {
		models.RespondError(conn, req.ID, "messageId and key are required")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if !b.HasCapability(CapReactions) {
		models.RespondError(conn, req.ID, fmt.Sprintf("%s has no reactions", provider))
		return
	}

	mine, err := m.Store().MyReaction(ctx, provider, chatID, messageID, key)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	if remove {
		if mine == "" {
			models.Respond(conn, req.ID, models.SuccessResult{Success: true})
			return
		}
		if _, err := b.call(ctx, MethodUnreact, map[string]any{
			"chatId": chatID, "messageId": messageID, "reactionId": mine, "key": key,
		}); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		if err := m.Store().DeleteReaction(ctx, provider, chatID, mine); err != nil {
			log.Warnf("chat: could not forget a reaction taken back: %v", err)
		}
		m.markDirty()
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
		return
	}

	if mine != "" {
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
		return
	}
	frame, err := b.call(ctx, MethodReact, map[string]any{
		"chatId": chatID, "messageId": messageID, "key": key,
	})
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	// Recorded at once rather than when the provider echoes it, so it is on
	// screen as soon as it is sent -- and so a second press takes it back
	// instead of reacting twice. The echo fills in the rest under the same id.
	var reply reactReply
	if len(frame.Result) > 0 {
		_ = json.Unmarshal(frame.Result, &reply)
	}
	if reply.ReactionID != "" {
		if err := m.Store().PutReactions(ctx, []chat.Reaction{{
			Provider: provider, ChatID: chatID, ID: reply.ReactionID, MessageID: messageID,
			Key: key, FromMe: true, TS: time.Now().UnixMilli(),
		}}); err != nil {
			log.Warnf("chat: could not record a reaction: %v", err)
		}
	}
	m.markDirty()
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleEdit replaces the text of one of our own messages.
//
// Only text, and only ours: an edit carries a whole new message on most
// services, and a caption edited as plain text would turn a photo into words on
// everybody else's screen.
func handleEdit(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}
	messageID := models.GetOr(req, "messageId", "")
	text := models.GetOr(req, "text", "")
	if messageID == "" {
		models.RespondError(conn, req.ID, "messageId is required")
		return
	}
	if strings.TrimSpace(text) == "" {
		models.RespondError(conn, req.ID, "an edit cannot leave a message empty; delete it instead")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if !b.HasCapability(CapEdit) {
		models.RespondError(conn, req.ID, fmt.Sprintf("%s cannot edit messages", provider))
		return
	}

	msg, err := m.Store().MessageByID(ctx, provider, chatID, messageID)
	if err != nil {
		models.RespondError(conn, req.ID, "that message is not stored here")
		return
	}
	switch {
	case !msg.FromMe:
		models.RespondError(conn, req.ID, "only your own messages can be edited")
		return
	case msg.Kind != chat.KindText:
		models.RespondError(conn, req.ID, "only text messages can be edited")
		return
	case msg.Status == chat.StatusPending || msg.Status == chat.StatusFailed:
		models.RespondError(conn, req.ID, "that message has not been sent yet")
		return
	case msg.Text == text:
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
		return
	}

	if _, err := b.call(ctx, MethodEdit, map[string]any{
		"chatId": chatID, "messageId": messageID, "text": text,
	}); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	if err := m.Store().EditMessage(ctx, provider, chatID, messageID, text); err != nil {
		log.Warnf("chat: could not record an edit: %v", err)
	}
	m.markDirty()
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleTyping tells a provider whether we are typing into a conversation.
//
// Never waited on and never an error: a typing notice that does not arrive is
// one nobody misses, and the shell sends another in a few seconds anyway.
func handleTyping(conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}
	typing := models.GetOr(req, "typing", true)

	if b, err := m.bridgeFor(provider); err == nil && b.HasCapability(CapTyping) {
		b.notify(MethodTyping, map[string]any{"chatId": chatID, "typing": typing})
	}
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

type startChatResponse struct {
	ChatID string `json:"chatId"`
	Name   string `json:"name,omitempty"`
}

// handleStartChat opens a conversation from what the user typed to reach it.
//
// What a handle is -- a user, a room address, a phone number -- is entirely the
// provider's business, and so are its words when it is not one.
func handleStartChat(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider := models.GetOr(req, "provider", "")
	handle := strings.TrimSpace(models.GetOr(req, "handle", ""))
	if provider == "" || handle == "" {
		models.RespondError(conn, req.ID, "provider and handle are required")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if !b.HasCapability(CapStartChat) {
		models.RespondError(conn, req.ID, fmt.Sprintf("%s cannot start conversations", provider))
		return
	}

	frame, err := b.call(ctx, MethodStartChat, map[string]any{"handle": handle})
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	var reply startChatReply
	if len(frame.Result) > 0 {
		_ = json.Unmarshal(frame.Result, &reply)
	}
	if reply.ChatID == "" {
		models.RespondError(conn, req.ID, fmt.Sprintf("%s did not say which conversation it opened", provider))
		return
	}

	// A row straight away, so the conversation opens under its name rather
	// than its id while the provider is still catching up with it.
	if err := m.Store().UpsertChat(ctx, chat.Chat{
		Provider: provider, ID: reply.ChatID, Name: reply.Name, Unread: -1,
	}); err != nil {
		log.Warnf("chat: could not record the conversation just started: %v", err)
	}
	m.markDirty()
	models.Respond(conn, req.ID, startChatResponse{ChatID: reply.ChatID, Name: reply.Name})
}

type membersResponse struct {
	Members []Member `json:"members"`
}

// handleMembers lists who is in a conversation, for the composer's "@" picker.
//
// A provider without the members capability answers with nobody rather than
// an error: the picker then offers whoever has written in the conversation,
// which the shell knows from the messages themselves.
func handleMembers(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if !b.HasCapability(CapMembers) {
		models.Respond(conn, req.ID, membersResponse{Members: []Member{}})
		return
	}

	frame, err := b.call(ctx, MethodMembers, map[string]any{"chatId": chatID})
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	var reply membersReply
	if len(frame.Result) > 0 {
		_ = json.Unmarshal(frame.Result, &reply)
	}
	members := make([]Member, 0, len(reply.Members))
	for _, member := range reply.Members {
		// A member nobody can be told apart by is no use in a picker.
		if member.ID == "" {
			continue
		}
		if member.Name == "" {
			member.Name = member.ID
		}
		members = append(members, member)
	}
	models.Respond(conn, req.ID, membersResponse{Members: members})
}

type fetchMediaResponse struct {
	Success bool   `json:"success"`
	Path    string `json:"path,omitempty"`
}

func handleFetchMedia(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}
	messageID, ok := models.Get[string](req, "messageId")
	if !ok || messageID == "" {
		models.RespondError(conn, req.ID, "messageId is required")
		return
	}

	// Already cached: hand back the path without troubling the bridge.
	if msg, err := m.Store().MessageByID(ctx, provider, chatID, messageID); err == nil && msg.MediaPath != "" {
		models.Respond(conn, req.ID, fetchMediaResponse{Success: true, Path: msg.MediaPath})
		return
	}

	ref, err := m.Store().MediaRefFor(ctx, provider, chatID, messageID)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if ref == "" {
		models.RespondError(conn, req.ID, "message has no fetchable media")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	frame, err := b.call(ctx, MethodFetchMedia, map[string]any{
		"chatId": chatID, "messageId": messageID, "ref": ref,
	})
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	var res fetchMediaResult
	if len(frame.Result) > 0 {
		_ = json.Unmarshal(frame.Result, &res)
	}

	var path string
	switch {
	case res.Path != "":
		path, err = m.Media().Adopt(provider, messageID, res.Mime, res.Path)
	case res.Bytes != "":
		path, err = m.Media().StoreBase64(provider, messageID, res.Mime, res.Bytes)
	default:
		err = fmt.Errorf("bridge returned no media")
	}
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	if err := m.Store().SetMediaPath(ctx, provider, chatID, messageID, path); err != nil {
		log.Warnf("chat: could not record media path: %v", err)
	}

	m.markDirty()
	models.Respond(conn, req.ID, fetchMediaResponse{Success: true, Path: path})
}

func handleAuth(ctx context.Context, conn *models.Conn, req models.Request, m *Manager, method string) {
	provider, ok := models.Get[string](req, "provider")
	if !ok || provider == "" {
		models.RespondError(conn, req.ID, "provider is required")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	if _, err := b.call(ctx, method, nil); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleAuthSubmit passes typed sign-in details to a provider's bridge.
//
// For providers that sign in with credentials rather than a scannable code --
// Matrix, a mail account, anything with an API key. The values go straight
// through to the bridge and are deliberately not stored, not logged and not
// written to settings: the bridge exchanges them for whatever token it keeps and
// they are gone from this process the moment the call returns.
func handleAuthSubmit(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, ok := models.Get[string](req, "provider")
	if !ok || provider == "" {
		models.RespondError(conn, req.ID, "provider is required")
		return
	}

	values, ok := models.Get[map[string]any](req, "values")
	if !ok || len(values) == 0 {
		models.RespondError(conn, req.ID, "values are required")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	if _, err := b.call(ctx, MethodAuthSubmit, map[string]any{"values": values}); err != nil {
		// The bridge's message is the useful one -- "wrong password", not
		// "call failed" -- so it is passed through rather than replaced.
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleRevoke deletes a message for everyone.
//
// The local tombstone is written only after the provider accepts it: showing a
// message as deleted when it is still on everyone else's screen would be a lie.
func handleRevoke(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}
	messageID, ok := models.Get[string](req, "messageId")
	if !ok || messageID == "" {
		models.RespondError(conn, req.ID, "messageId is required")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if !b.HasCapability(CapRevoke) {
		models.RespondError(conn, req.ID, fmt.Sprintf("%s cannot delete messages", provider))
		return
	}

	if _, err := b.call(ctx, MethodRevoke, map[string]any{
		"chatId": chatID, "messageId": messageID,
	}); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	if err := m.Store().MarkDeleted(ctx, provider, chatID, messageID); err != nil {
		log.Warnf("chat: could not mark message deleted: %v", err)
	}

	m.markDirty()
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleInvite answers an invitation to a conversation: joining it, or turning
// it down.
//
// A declined invitation is removed locally as well, because nothing else ever
// will: the provider stops mentioning a conversation the moment it is declined,
// so a row left behind would sit in the list forever, offering to open
// something that no longer exists. Only a conversation nobody has written in is
// removed -- an invitation back into a room with history in it leaves that
// history alone.
func handleInvite(ctx context.Context, conn *models.Conn, req models.Request, m *Manager, accept bool) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if !b.HasCapability(CapInvites) {
		models.RespondError(conn, req.ID, fmt.Sprintf("%s has no invitations to answer", provider))
		return
	}

	method := MethodDeclineInvite
	if accept {
		method = MethodAcceptInvite
	}
	if _, err := b.call(ctx, method, map[string]any{"chatId": chatID}); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	if !accept {
		if err := m.Store().DeleteChatIfUnwritten(ctx, provider, chatID); err != nil {
			log.Warnf("chat: could not remove the declined invitation %s/%s: %v", provider, chatID, err)
		}
	}

	m.markDirty()
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handleDeleteLocal removes a message from this device only.
//
// Distinct from revoke: nothing is sent anywhere, everyone else keeps their
// copy, and it works on any provider because it touches only our own store.
func handleDeleteLocal(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, chatID, ok := chatTarget(conn, req)
	if !ok {
		return
	}
	messageID, ok := models.Get[string](req, "messageId")
	if !ok || messageID == "" {
		models.RespondError(conn, req.ID, "messageId is required")
		return
	}

	if err := m.Store().DeleteMessage(ctx, provider, chatID, messageID); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	m.markDirty()
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

// handlePurge forgets everything stored for a provider. Used when signing out.
func handlePurge(ctx context.Context, conn *models.Conn, req models.Request, m *Manager) {
	provider, ok := models.Get[string](req, "provider")
	if !ok || provider == "" {
		models.RespondError(conn, req.ID, "provider is required")
		return
	}

	if err := m.Store().PurgeProvider(ctx, provider); err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}
	if err := m.Media().PurgeProvider(provider); err != nil {
		log.Warnf("chat: could not purge media for %s: %v", provider, err)
	}

	m.markDirty()
	models.Respond(conn, req.ID, models.SuccessResult{Success: true})
}

type authQRResult struct {
	Method  string `json:"method"`
	Payload string `json:"payload,omitempty"`
	// Path is the rendered QR, black-on-white so it reads on the light plate
	// every consumer draws behind it.
	Path string `json:"path,omitempty"`
}

// handleAuthQRCode renders the provider's pending sign-in challenge.
//
// Rendering is done here rather than by each bridge: device linking by QR is
// near-universal, and asking every bridge author to produce a PNG would be
// asking them all to solve the same problem.
func handleAuthQRCode(conn *models.Conn, req models.Request, m *Manager) {
	provider, ok := models.Get[string](req, "provider")
	if !ok || provider == "" {
		models.RespondError(conn, req.ID, "provider is required")
		return
	}

	b, err := m.bridgeFor(provider)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	method, payload := b.AuthChallenge()
	if payload == "" {
		models.RespondError(conn, req.ID, "no sign-in challenge pending")
		return
	}

	// A code or URL is shown as text; only a QR needs an image.
	if method != "qr" {
		models.Respond(conn, req.ID, authQRResult{Method: method, Payload: payload})
		return
	}

	path, err := renderAuthQRCode(m.Media().Root(), provider, payload)
	if err != nil {
		models.RespondError(conn, req.ID, err.Error())
		return
	}

	models.Respond(conn, req.ID, authQRResult{Method: method, Path: path})
}

// handleTap streams a bridge's protocol traffic to the caller until the
// connection drops. It is the only chat method that writes more than one
// response, reusing the request id the way subscribe does.
//
// This is what makes a bridge debuggable: it runs as a child of the daemon, so
// without a tap its stdin and stdout are invisible to its own author.
func handleTap(conn *models.Conn, req models.Request, m *Manager) {
	provider := models.GetOr(req, "provider", "")

	m.mu.RLock()
	var targets []*bridge
	for id, b := range m.bridges {
		if provider == "" || id == provider {
			targets = append(targets, b)
		}
	}
	known := len(m.providers)
	m.mu.RUnlock()

	if len(targets) == 0 {
		if provider != "" {
			models.RespondError(conn, req.ID,
				fmt.Sprintf("chat provider %q is not running; enable it first", provider))
			return
		}
		models.RespondError(conn, req.ID,
			fmt.Sprintf("no chat bridges are running (%d installed)", known))
		return
	}

	lines := make(chan TapLine, 256)
	var detachers []func()
	for _, b := range targets {
		ch, detach := b.Tap()
		detachers = append(detachers, detach)

		go func(ch <-chan TapLine) {
			for line := range ch {
				select {
				case lines <- line:
				default:
				}
			}
		}(ch)
	}
	defer func() {
		for _, detach := range detachers {
			detach()
		}
	}()

	// A failed write means the client hung up, which is the only exit path.
	for line := range lines {
		if err := conn.WriteResponse(models.Response[TapLine]{ID: req.ID, Result: &line}); err != nil {
			return
		}
	}
}

// chatTarget pulls the provider and chat id every per-chat method needs,
// responding with an error and returning false when either is missing.
func chatTarget(conn *models.Conn, req models.Request) (provider, chatID string, ok bool) {
	provider, ok = models.Get[string](req, "provider")
	if !ok || provider == "" {
		models.RespondError(conn, req.ID, "provider is required")
		return "", "", false
	}
	chatID, ok = models.Get[string](req, "chatId")
	if !ok || chatID == "" {
		models.RespondError(conn, req.ID, "chatId is required")
		return "", "", false
	}
	return provider, chatID, true
}
