package host

import (
	"testing"
	"time"

	"dmschatmanager/internal/chat"
	"github.com/stretchr/testify/assert"
)

func heldMessage(chatID string) chat.Message {
	return chat.Message{
		Provider: "p", ChatID: chatID, ID: chatID + "-1", Kind: chat.KindText,
		Text: "hi", TS: time.Now().UnixMilli(),
	}
}

// A provider that has just connected is replaying what we missed, not
// reporting news. Announcing that on the way through is how a reconnect turns
// into a burst of notifications for conversations already dealt with.
func TestMessagesAreHeldUntilAProviderSettles(t *testing.T) {
	m := newTestManager(t, t.TempDir())

	assert.True(t, m.holdNotification("p", heldMessage("c1")),
		"a provider that has not finished connecting must not notify yet")

	m.noteProviderState("p", chat.StateConnected)
	assert.True(t, m.holdNotification("p", heldMessage("c2")),
		"connected is not the end of the catch-up; the settling window still holds")

	eventually(t, "the settling window to close", func() bool { return m.isSettled("p") })

	assert.False(t, m.holdNotification("p", heldMessage("c3")),
		"once settled, a message notifies as it arrives")

	// Losing the connection means the next batch is another catch-up.
	m.noteProviderState("p", chat.StateConnecting)
	assert.True(t, m.holdNotification("p", heldMessage("c4")))
}

// Held messages are bounded: a provider replaying thousands must not grow the
// held list without limit. They are still stored and still unread, they simply
// do not each get a notification.
func TestHeldMessagesAreBounded(t *testing.T) {
	m := newTestManager(t, t.TempDir())

	for i := 0; i < maxHeld+50; i++ {
		m.holdNotification("p", heldMessage("c1"))
	}

	m.mu.RLock()
	held := len(m.held["p"])
	m.mu.RUnlock()
	assert.Equal(t, maxHeld, held)
}

// Switching a provider off drops what it was holding: nothing should notify
// minutes later for conversations that are no longer shown.
func TestDisablingAProviderDropsHeldMessages(t *testing.T) {
	m := newTestManager(t, t.TempDir())

	m.holdNotification("p", heldMessage("c1"))
	m.stopSettling("p")

	m.mu.RLock()
	_, stillHeld := m.held["p"]
	_, stillTimed := m.settleJob["p"]
	m.mu.RUnlock()

	assert.False(t, stillHeld, "held messages outlived the provider")
	assert.False(t, stillTimed, "the settling timer outlived the provider")
}
