package chat

import (
	"context"
	"strconv"
	"strings"
	"sync"
	"time"

	"dmschatmanager/internal/log"
	"dmschatmanager/internal/notify"
)

// NotifyAppName is what a chat notification says it came from when the
// provider has no name of its own. Normally it is the provider's name --
// "Matrix", "Signal" -- which says more in fewer letters, and is what a
// notification rule matches to quiet one service without the others. Either
// way it is distinct from the shell's own "DMS".
const NotifyAppName = "DMS Chats"

// maxRoomInTitle is how much of a group's name goes after the sender's in a
// notification's title. The title shares its line with the message on a
// one-line notification, and a group called "İYC Mersin 2025-2026 Erkek
// Öğrenci Yurdu" left no room for what was said in it.
const maxRoomInTitle = 24

// NotifyPrefs is the effective notification policy for one provider.
//
// Held per provider rather than globally because the right answer differs: a
// work account may want silence while a family one does not, and a single
// global setting lets the noisiest provider decide for all of them.
type NotifyPrefs struct {
	// Enabled turns notifications off for this provider entirely.
	Enabled bool `json:"enabled"`
	// Preview shows the message body; off shows only that something arrived.
	Preview bool `json:"preview"`
	// Groups notifies for group conversations.
	Groups bool `json:"groups"`
	// Archived notifies for conversations the user has put away.
	Archived bool `json:"archived"`
	// DoNotDisturb silences the provider without discarding the settings above,
	// so turning it back off restores what the user had chosen.
	DoNotDisturb bool `json:"doNotDisturb"`
	// MutedTags silences whole categories a provider defines -- a service's
	// statuses or channels, a mail account's labels -- without silencing the
	// provider itself. Which tags exist is up to the provider, so this is a
	// list rather than a fixed set of flags.
	MutedTags []string `json:"mutedTags,omitempty"`
}

// DefaultNotifyPrefs is the conservative starting point: notify with previews
// for direct and group messages, but stay quiet for archived conversations.
func DefaultNotifyPrefs() NotifyPrefs {
	return NotifyPrefs{Enabled: true, Preview: true, Groups: true, Archived: false}
}

// NotifyPolicy decides which arriving messages are worth interrupting someone
// for. It is the whole reason a bridge never calls notify-send itself: get this
// wrong once and a first login fires several hundred notifications at a user.
type NotifyPolicy struct {
	store NotifyStore
	media *Media

	// StartedAt is when the host came up. Anything older is backfill.
	StartedAt time.Time

	// mu guards everything below: the shell pushes focus down on one goroutine
	// while messages are judged on another, and clicks arrive on a third.
	mu sync.Mutex

	// focused is the chat currently on screen, pushed down by the shell. A
	// message you are already looking at should not also buzz.
	focused focusKey

	// shown remembers which conversation each notification raised here is
	// about, so a click on one can open it. Bounded by maxRemembered, oldest
	// forgotten first, through shownOrder.
	shown      map[uint32]focusKey
	shownOrder []uint32
}

// maxRemembered is how many notifications are remembered for answering a
// click: far more than are ever on screen at once. A click on one older than
// that opens the chat window rather than guessing.
const maxRemembered = 256

// openActions are what every chat notification offers. "default" is what a
// notification server invokes when the notification itself is clicked, which
// is the only action anybody looks for on a message: take me to it.
var openActions = []string{"default", "Open"}

type focusKey struct {
	provider string
	chatID   string
}

// NewNotifyPolicy returns a policy anchored at the current time, so anything
// older than this instant counts as backfill.
// NotifyStore is the little of the store that deciding whether to notify needs.
//
// An interface rather than the store itself so this works the same whether
// there is one database or one per provider.
type NotifyStore interface {
	ChatByID(ctx context.Context, provider, chatID string) (Chat, error)
	IsArchived(ctx context.Context, provider, chatID string) bool
	IsMuted(ctx context.Context, provider, chatID string) bool
}

func NewNotifyPolicy(store NotifyStore, media *Media) *NotifyPolicy {
	return &NotifyPolicy{
		store:     store,
		media:     media,
		StartedAt: time.Now(),
		shown:     map[uint32]focusKey{},
	}
}

// SetFocus records which chat is on screen. An empty chatID means none is.
func (p *NotifyPolicy) SetFocus(provider, chatID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.focused = focusKey{provider: provider, chatID: chatID}
}

// Focused reports the chat currently on screen.
func (p *NotifyPolicy) Focused() (provider, chatID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.focused.provider, p.focused.chatID
}

// isFocused reports whether a conversation is the one on screen.
func (p *NotifyPolicy) isFocused(provider, chatID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.focused.provider == provider && p.focused.chatID == chatID
}

// remember records which conversation a notification is about. An empty
// target is a notification about several at once.
func (p *NotifyPolicy) remember(id uint32, target focusKey) {
	if id == 0 {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	if p.shown == nil {
		p.shown = map[uint32]focusKey{}
	}
	if _, known := p.shown[id]; !known {
		p.shownOrder = append(p.shownOrder, id)
	}
	p.shown[id] = target

	for len(p.shownOrder) > maxRemembered {
		delete(p.shown, p.shownOrder[0])
		p.shownOrder = p.shownOrder[1:]
	}
}

// Target is the conversation a notification raised here is about.
//
// ok is false for a notification this process does not know -- another app's,
// or one raised before a restart. A notification about several conversations
// at once is known, with an empty chatID: the place for it is the window.
func (p *NotifyPolicy) Target(id uint32) (provider, chatID string, ok bool) {
	p.mu.Lock()
	defer p.mu.Unlock()

	target, ok := p.shown[id]
	return target.provider, target.chatID, ok
}

// Forget drops a notification that has gone away.
func (p *NotifyPolicy) Forget(id uint32) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if _, ok := p.shown[id]; !ok {
		return
	}
	delete(p.shown, id)
	for i, known := range p.shownOrder {
		if known == id {
			p.shownOrder = append(p.shownOrder[:i], p.shownOrder[i+1:]...)
			break
		}
	}
}

const (
	// catchUpWindow is how far back a message held during a sync may be and
	// still be worth interrupting someone for.
	//
	// A shell restarted a minute ago should still say what arrived while it was
	// down; a message from yesterday has had its chance, and would otherwise be
	// announced afresh on every single start -- nothing remembers what has
	// already been notified, and nothing should have to.
	catchUpWindow = 30 * time.Minute

	// How many conversations get their own notification when a provider
	// finishes catching up. Past this they are counted in one line: coming back
	// to a full inbox is one fact, not thirty.
	maxCatchUpNotifications = 5
)

// suppressionReason returns why a message should not notify, or "" to notify.
func (p *NotifyPolicy) suppressionReason(ctx context.Context, m Message, prefs NotifyPrefs) string {
	return p.suppress(ctx, m, prefs, 0)
}

// suppress is suppressionReason with an allowance on how old a message may be.
//
// grace is what separates a live message from one recovered after a sync: live
// traffic older than this host is history and never notifies, while a message
// missed during a restart is exactly what the user wants to hear about.
//
// The order matters: the cheap, certain checks come before anything that hits
// the database.
func (p *NotifyPolicy) suppress(ctx context.Context, m Message, prefs NotifyPrefs, grace time.Duration) string {
	if prefs.DoNotDisturb {
		return "do not disturb"
	}
	if !prefs.Enabled {
		return "notifications disabled"
	}

	// Your own messages, including ones echoed back from another device.
	if m.FromMe {
		return "own message"
	}

	// Bookkeeping rows are not something a person said.
	if isProtocolKind(m.Kind) {
		return "protocol message"
	}

	// Backfill. History sync delivers messages that predate the host starting;
	// without this, a first login notifies for the user's entire history.
	if m.TS > 0 && !time.UnixMilli(m.TS).After(p.StartedAt.Add(-grace)) {
		return "backfill"
	}

	// The conversation is already on screen.
	if p.isFocused(m.Provider, m.ChatID) {
		return "chat focused"
	}

	// Read somewhere else. A provider that knows its own read position pushes
	// it down, and a message at or before it has been seen -- on a phone, in
	// another client -- whatever this device happens to have stored.
	if p.store != nil && m.TS > 0 {
		if c, err := p.store.ChatByID(ctx, m.Provider, m.ChatID); err == nil && c.ReadUpTo >= m.TS {
			return "already read"
		}
	}

	if p.store != nil {
		if p.store.IsMuted(ctx, m.Provider, m.ChatID) {
			return "chat muted"
		}
		// Archiving is how a user says "keep this out of my way".
		if !prefs.Archived && p.store.IsArchived(ctx, m.Provider, m.ChatID) {
			return "chat archived"
		}
	}

	// A message that names the user gets through: turning group notifications
	// off is not asking to miss being spoken to.
	if !prefs.Groups && !m.Highlight && p.isGroup(ctx, m) {
		return "group message"
	}

	if tag := p.mutedTag(ctx, m, prefs); tag != "" {
		return "muted tag: " + tag
	}

	return ""
}

// mutedTag returns the tag that silences this message, or "".
func (p *NotifyPolicy) mutedTag(ctx context.Context, m Message, prefs NotifyPrefs) string {
	if len(prefs.MutedTags) == 0 || p.store == nil {
		return ""
	}

	c, err := p.store.ChatByID(ctx, m.Provider, m.ChatID)
	if err != nil {
		return ""
	}

	for _, tag := range c.Tags {
		for _, muted := range prefs.MutedTags {
			if tag == muted {
				return tag
			}
		}
	}
	return ""
}

func (p *NotifyPolicy) isGroup(ctx context.Context, m Message) bool {
	if p.store == nil {
		return false
	}
	c, err := p.store.ChatByID(ctx, m.Provider, m.ChatID)
	return err == nil && c.IsGroup
}

// Notify raises a desktop notification for an arriving message unless policy
// suppresses it. Reports whether a notification was actually shown.
func (p *NotifyPolicy) Notify(ctx context.Context, m Message, providerName string, prefs NotifyPrefs) bool {
	if reason := p.suppressionReason(ctx, m, prefs); reason != "" {
		log.Debugf("chat: suppressed notification for %s/%s: %s", m.Provider, m.ChatID, reason)
		return false
	}
	return p.send(p.notificationFor(ctx, m, providerName, prefs), focusKey{provider: m.Provider, chatID: m.ChatID})
}

// NotifyCatchUp announces messages that were held while a provider was still
// syncing -- see settle.go in the host package.
//
// One notification per conversation, however many messages it holds: coming
// back to a day of traffic should cost a handful of notifications, not a
// hundred. Everything is re-judged first, which is the entire reason for
// having waited: by now the provider has said how far each conversation was
// read elsewhere, and most of a catch-up usually turns out to be already seen.
//
// Reports how many notifications were shown.
func (p *NotifyPolicy) NotifyCatchUp(ctx context.Context, msgs []Message, providerName string, prefs NotifyPrefs) int {
	// Grouped in arrival order, so conversations are announced in the order
	// their first unread message came in rather than in map order.
	order := make([]string, 0, len(msgs))
	byChat := make(map[string][]Message, len(msgs))

	for _, m := range msgs {
		if reason := p.suppress(ctx, m, prefs, catchUpWindow); reason != "" {
			log.Debugf("chat: held message from %s/%s not notified: %s", m.Provider, m.ChatID, reason)
			continue
		}
		if _, seen := byChat[m.ChatID]; !seen {
			order = append(order, m.ChatID)
		}
		byChat[m.ChatID] = append(byChat[m.ChatID], m)
	}

	shown := 0
	for i, chatID := range order {
		if i == maxCatchUpNotifications {
			// The rest as one line. Thirty conversations is a state of affairs,
			// not thirty things to be told one after another.
			remaining := len(order) - i
			p.send(notify.Notification{
				AppName: appNameFor(providerName),
				Icon:    "material:chat",
				Summary: providerNameOr(providerName),
				Body:    plural(remaining, "more conversation", "more conversations") + " with unread messages",
				Actions: openActions,
			}, focusKey{})
			shown++
			break
		}

		group := byChat[chatID]
		latest := group[len(group)-1]

		n := p.notificationFor(ctx, latest, providerName, prefs)
		if len(group) > 1 {
			// The newest message, with a count of how much is waiting behind
			// it beside the name. A count alone says nothing about whether it
			// matters -- and in the body it pushed the message off a one-line
			// notification.
			n.Summary += " (" + strconv.Itoa(len(group)) + ")"
		}
		if p.send(n, focusKey{provider: latest.Provider, chatID: latest.ChatID}) {
			shown++
		}
	}
	return shown
}

// appNameFor is the provider's name as a notification's source: "Matrix" for
// the plugin called "Matrix Chat", since every one of them is a chat.
func appNameFor(providerName string) string {
	name := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(providerName), " Chat"))
	if name == "" {
		return NotifyAppName
	}
	return name
}

func providerNameOr(providerName string) string {
	if providerName != "" {
		return providerName
	}
	return "Chats"
}

// notificationFor builds what one message looks like on screen.
//
// Who in the title, what in the body, and nothing else in either: the title is
// the person -- with the group after them, shortened, when it is one -- and the
// body is the message alone. The body used to start with the sender too, which
// on a one-line notification left the message a few letters wide.
func (p *NotifyPolicy) notificationFor(ctx context.Context, m Message, providerName string, prefs NotifyPrefs) notify.Notification {
	body := "New message"
	if prefs.Preview {
		// Without its formatting markers, which a notification cannot draw.
		if preview := StripMarkup(m.Preview()); preview != "" {
			body = preview
		}
	}

	c, haveChat := Chat{}, false
	if p.store != nil {
		if found, err := p.store.ChatByID(ctx, m.Provider, m.ChatID); err == nil {
			c, haveChat = found, true
		}
	}

	n := notify.Notification{
		AppName: appNameFor(providerName),
		Icon:    "material:chat",
		Summary: p.titleFor(m, c, haveChat, providerName),
		Body:    body,
		Actions: openActions,
	}

	// An image attachment shows as the notification's own preview; otherwise
	// the picture of whoever wrote, which says who it is before a word is
	// read. Only files already cached -- notifying must never trigger a
	// download.
	switch {
	case prefs.Preview && m.Kind == KindImage && m.MediaPath != "":
		n.FilePath = m.MediaPath
	case haveChat && c.IsGroup && m.SenderAvatarPath != "":
		n.FilePath = m.SenderAvatarPath
	case haveChat && c.AvatarPath != "":
		n.FilePath = c.AvatarPath
	case m.SenderAvatarPath != "":
		n.FilePath = m.SenderAvatarPath
	}
	return n
}

// send shows a notification and remembers what it is about, so a click on it
// can be answered with the conversation it names.
func (p *NotifyPolicy) send(n notify.Notification, target focusKey) bool {
	id, err := notify.Send(n)
	if err != nil {
		log.Warnf("chat: notification failed: %v", err)
		return false
	}
	p.remember(id, target)
	return true
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

// titleFor names who a message is from: the person in a direct conversation,
// "person · group" in a group, never a raw identifier -- see ShortName.
func (p *NotifyPolicy) titleFor(m Message, c Chat, haveChat bool, providerName string) string {
	room := ""
	if haveChat {
		room = ShortName(c.Name)
	}
	sender := ShortName(m.SenderName)

	if haveChat && c.IsGroup {
		switch {
		case sender != "" && room != "":
			return sender + " · " + clipRunes(room, maxRoomInTitle)
		case room != "":
			return room
		}
	}
	if room != "" {
		return room
	}
	if sender != "" {
		return sender
	}
	return providerNameOr(providerName)
}

// clipRunes shortens text to at most limit characters, ending it with "…".
func clipRunes(text string, limit int) string {
	runes := []rune(text)
	if len(runes) <= limit {
		return text
	}
	return strings.TrimRight(string(runes[:limit-1]), " -·,") + "…"
}
