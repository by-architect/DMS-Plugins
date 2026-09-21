package host

import (
	"context"
	"time"

	"dmschatmanager/internal/chat"
	"dmschatmanager/internal/log"
)

// Holding notifications until a provider has finished catching up.
//
// A bridge that has just connected is not reporting news. It is replaying what
// happened while nobody was listening -- messages from this morning, read on a
// phone hours ago -- and every one of them looks live to a host that only knows
// when it received it. Notifying on the way through means a burst of alerts for
// conversations the user has already dealt with, which is worse than useless:
// it teaches them to ignore the ones that matter.
//
// So messages that arrive before a provider says it is connected are held, and
// judged when the dust settles: anything the service itself says has been read
// is dropped, and what remains is announced one notification per conversation.
const (
	// How long after a provider reports connected before its held messages are
	// judged. Long enough for the read positions that arrive with the same
	// sync to land, short enough not to feel like a delay.
	settleDelay = 3 * time.Second

	// The backstop, for a provider that never reports connected at all. Held
	// messages are not allowed to sit silently forever.
	maxHold = 45 * time.Second

	// How many messages are held per provider. Past this the oldest are
	// dropped: they are still stored and still unread, they simply do not get
	// their own notification.
	maxHeld = 500
)

// noteProviderState starts or stops the settling window as a provider connects
// and disconnects.
func (m *Manager) noteProviderState(provider, state string) {
	if state == chat.StateConnected {
		// Connected means the first sync is through, not that everything it
		// brought has been dealt with -- hence the delay rather than flushing
		// on the spot.
		m.scheduleSettle(provider, settleDelay, true)
		return
	}

	// Reconnecting, signing in again, or gone: whatever comes next is another
	// catch-up, so hold it like the first one.
	m.mu.Lock()
	m.settled[provider] = false
	m.mu.Unlock()
}

// isSettled reports whether a provider has finished catching up, and so
// whether an arriving message is news rather than history.
func (m *Manager) isSettled(provider string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.settled[provider]
}

// holdNotification stores a message instead of notifying for it, and reports
// whether it did.
func (m *Manager) holdNotification(provider string, msg chat.Message) bool {
	m.mu.Lock()
	if m.settled[provider] {
		m.mu.Unlock()
		return false
	}

	held := append(m.held[provider], msg)
	if len(held) > maxHeld {
		held = held[len(held)-maxHeld:]
	}
	m.held[provider] = held
	first := len(held) == 1
	m.mu.Unlock()

	if first {
		// The backstop starts with the first held message rather than at
		// startup, so a provider nobody is talking to never arms it.
		m.scheduleSettle(provider, maxHold, false)
	}
	return true
}

// scheduleSettle arms the timer that ends a provider's settling window.
//
// reschedule is what tells a later, better signal -- the provider reporting
// connected -- that it may bring the backstop forward.
func (m *Manager) scheduleSettle(provider string, after time.Duration, reschedule bool) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if timer, ok := m.settleJob[provider]; ok {
		if !reschedule {
			return
		}
		timer.Stop()
	}
	m.settleJob[provider] = time.AfterFunc(after, func() { m.settle(provider) })
}

// settle ends the window: whatever is still unread gets its notification.
func (m *Manager) settle(provider string) {
	m.mu.Lock()
	msgs := m.held[provider]
	delete(m.held, provider)
	delete(m.settleJob, provider)
	m.settled[provider] = true
	m.mu.Unlock()

	if len(msgs) == 0 {
		return
	}

	// Outside the lock: both of these take it themselves, and notifying is a
	// round trip to the notification daemon.
	prefs := m.ProviderPrefs(provider)
	name := m.providerName(provider)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if shown := m.notify.NotifyCatchUp(ctx, msgs, name, prefs); shown > 0 {
		log.Infof("chat: %s caught up: %d message(s) held, %d notification(s)", provider, len(msgs), shown)
	}
}

// stopSettling drops anything held for a provider, used when it is switched off
// so a disabled provider cannot notify minutes later.
func (m *Manager) stopSettling(provider string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if timer, ok := m.settleJob[provider]; ok {
		timer.Stop()
		delete(m.settleJob, provider)
	}
	delete(m.held, provider)
	delete(m.settled, provider)
}
