package chat

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The suppression ladder is tested directly rather than through Notify, which
// needs a session bus. Getting this wrong is what turns a first login into
// several hundred notifications, so each rule gets its own case.
func TestSuppressionLadder(t *testing.T) {
	ctx := context.Background()
	store := newStore(t)
	started := time.Now()

	require.NoError(t, store.TouchChat(ctx, prov, "dm", "Ada", "", started.UnixMilli(), false, false))
	require.NoError(t, store.TouchChat(ctx, prov, "group", "Team", "", started.UnixMilli(), true, false))
	require.NoError(t, store.TouchChat(ctx, prov, "muted", "Noisy", "", started.UnixMilli(), false, false))
	require.NoError(t, store.SetMuted(ctx, prov, "muted", true))
	require.NoError(t, store.TouchChat(ctx, prov, "filed", "Away", "", started.UnixMilli(), false, false))
	require.NoError(t, store.SetArchived(ctx, prov, "filed", true))

	// A message that arrived after start, from someone else, in a normal chat.
	fresh := func(chatID string) Message {
		return Message{
			Provider: prov, ChatID: chatID, ID: "m1", Kind: KindText, Text: "hi",
			TS: started.Add(time.Minute).UnixMilli(),
		}
	}

	newPolicy := func() *NotifyPolicy {
		p := NewNotifyPolicy(store, nil)
		p.StartedAt = started
		return p
	}

	// Prefs travel with each call now, so every case states the policy it is
	// exercising instead of mutating shared state.
	defaults := DefaultNotifyPrefs()

	t.Run("notifies for a normal incoming message", func(t *testing.T) {
		assert.Empty(t, newPolicy().suppressionReason(ctx, fresh("dm"), defaults))
	})

	t.Run("disabled", func(t *testing.T) {
		prefs := defaults
		prefs.Enabled = false
		assert.Equal(t, "notifications disabled", newPolicy().suppressionReason(ctx, fresh("dm"), prefs))
	})

	t.Run("do not disturb outranks everything else", func(t *testing.T) {
		prefs := defaults
		prefs.DoNotDisturb = true
		assert.Equal(t, "do not disturb", newPolicy().suppressionReason(ctx, fresh("dm"), prefs))
	})

	t.Run("own message", func(t *testing.T) {
		m := fresh("dm")
		m.FromMe = true
		assert.Equal(t, "own message", newPolicy().suppressionReason(ctx, m, defaults))
	})

	t.Run("protocol kinds", func(t *testing.T) {
		for _, kind := range []string{KindSystem, KindDeleted, KindUnsupported} {
			m := fresh("dm")
			m.Kind = kind
			assert.Equal(t, "protocol message", newPolicy().suppressionReason(ctx, m, defaults), kind)
		}
	})

	t.Run("backfill predating startup", func(t *testing.T) {
		m := fresh("dm")
		m.TS = started.Add(-time.Hour).UnixMilli()
		assert.Equal(t, "backfill", newPolicy().suppressionReason(ctx, m, defaults))
	})

	t.Run("focused chat", func(t *testing.T) {
		p := newPolicy()
		p.SetFocus(prov, "dm")
		assert.Equal(t, "chat focused", p.suppressionReason(ctx, fresh("dm"), defaults))
		assert.Empty(t, p.suppressionReason(ctx, fresh("group"), defaults),
			"focusing one chat does not mute the others")
	})

	t.Run("muted chat", func(t *testing.T) {
		assert.Equal(t, "chat muted", newPolicy().suppressionReason(ctx, fresh("muted"), defaults))
	})

	t.Run("archived chat", func(t *testing.T) {
		assert.Equal(t, "chat archived", newPolicy().suppressionReason(ctx, fresh("filed"), defaults))

		prefs := defaults
		prefs.Archived = true
		assert.Empty(t, newPolicy().suppressionReason(ctx, fresh("filed"), prefs),
			"archived chats notify when the user opts in")
	})

	// Its own conversation: a read position only ever moves forward, so this
	// cannot be undone for the cases after it.
	t.Run("already read where the provider said so", func(t *testing.T) {
		m := fresh("elsewhere")
		require.NoError(t, store.TouchChat(ctx, prov, "elsewhere", "Bea", "", started.UnixMilli(), false, false))

		// The provider reports the conversation read past this message, as it
		// does after it was read on a phone.
		require.NoError(t, store.SetReadUpTo(ctx, prov, "elsewhere", m.TS+1))
		assert.Equal(t, "already read", newPolicy().suppressionReason(ctx, m, defaults))

		newer := m
		newer.TS = m.TS + 1000
		assert.Empty(t, newPolicy().suppressionReason(ctx, newer, defaults),
			"a message arriving after the read position is still unread")
	})

	t.Run("group messages when groups are off", func(t *testing.T) {
		assert.Empty(t, newPolicy().suppressionReason(ctx, fresh("group"), defaults))

		prefs := defaults
		prefs.Groups = false
		assert.Equal(t, "group message", newPolicy().suppressionReason(ctx, fresh("group"), prefs))
		assert.Empty(t, newPolicy().suppressionReason(ctx, fresh("dm"), prefs),
			"turning off groups leaves direct messages alone")
	})
}

// Focus is scoped per provider: the same chat id in two services is two chats.
func TestFocusIsProviderScoped(t *testing.T) {
	ctx := context.Background()
	store := newStore(t)

	p := NewNotifyPolicy(store, nil)
	p.StartedAt = time.Now().Add(-time.Hour)
	p.SetFocus("alpha", "shared")

	provider, chatID := p.Focused()
	assert.Equal(t, "alpha", provider)
	assert.Equal(t, "shared", chatID)

	m := Message{Provider: "beta", ChatID: "shared", ID: "m1", Kind: KindText,
		Text: "hi", TS: time.Now().UnixMilli()}
	assert.Empty(t, p.suppressionReason(ctx, m, DefaultNotifyPrefs()))
}

func TestMessagePreview(t *testing.T) {
	assert.Equal(t, "hello", Message{Kind: KindText, Text: "hello"}.Preview())
	assert.Equal(t, "📷 Photo", Message{Kind: KindImage}.Preview())
	assert.Equal(t, "🎤 Voice message", Message{Kind: KindAudio}.Preview())
	assert.Equal(t, "caption", Message{Kind: KindImage, Text: "caption"}.Preview(),
		"a caption wins over the placeholder")
	assert.Equal(t, "📄 report.pdf", Message{Kind: KindDocument, FileName: "report.pdf"}.Preview(),
		"a named attachment shows its name, not a generic label")
	assert.Empty(t, Message{Kind: KindText}.Preview())
}

// What survives a catch-up, and what does not.
//
// The whole point of holding these is that by now the provider has said how far
// each conversation was read elsewhere -- so most of a catch-up turns out to be
// already seen, and what is left is worth one notification per conversation
// rather than one per message.
func TestCatchUpJudgesHeldMessages(t *testing.T) {
	ctx := context.Background()
	store := newStore(t)
	started := time.Now()

	require.NoError(t, store.TouchChat(ctx, prov, "dm", "Ada", "", started.UnixMilli(), false, false))
	require.NoError(t, store.TouchChat(ctx, prov, "seen", "Bea", "", started.UnixMilli(), false, false))

	p := NewNotifyPolicy(store, nil)
	p.StartedAt = started
	prefs := DefaultNotifyPrefs()

	held := func(chatID string, at time.Time) Message {
		return Message{
			Provider: prov, ChatID: chatID, ID: chatID + at.String(), Kind: KindText,
			Text: "hi", TS: at.UnixMilli(),
		}
	}

	// Read on a phone five minutes ago, after the message arrived.
	missed := started.Add(-10 * time.Minute)
	require.NoError(t, store.SetReadUpTo(ctx, prov, "seen", started.Add(-5*time.Minute).UnixMilli()))

	msgs := []Message{
		held("dm", missed),                    // missed while we were down
		held("seen", missed),                  // missed, but read elsewhere since
		held("dm", started.Add(-2*time.Hour)), // too old to still be news
	}

	kept := []Message{}
	for _, m := range msgs {
		if p.suppress(ctx, m, prefs, catchUpWindow) == "" {
			kept = append(kept, m)
		}
	}

	require.Len(t, kept, 1, "only the genuinely missed message survives")
	assert.Equal(t, "dm", kept[0].ChatID)

	// Without the catch-up allowance, even that one counts as history: a live
	// message older than the host is backfill.
	assert.Equal(t, "backfill", p.suppress(ctx, kept[0], prefs, 0))
}
