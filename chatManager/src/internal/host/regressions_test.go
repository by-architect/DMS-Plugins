package host

import (
	"context"
	"testing"
	"time"

	"dmschatmanager/internal/chat"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A bridge that answers everything except a send, which it dies on instead.
const dyingScript = `#!/bin/sh
echo '{"event":"ready","protocol":1,"capabilities":["send"]}'
echo '{"event":"state","state":"connected"}'
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"send"'*) exit 3 ;;
    *) echo "{\"id\":$id,\"ok\":true}" ;;
  esac
done
`

// A bridge dying with a send in flight has not sent anything. The call used to
// read the closed reply channel as an answer, and the message was marked sent.
func TestSendToADyingBridgeFails(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "dying", "", dyingScript)

	m := newTestManager(t, root)
	ctx := context.Background()
	require.NoError(t, m.SetEnabled(ctx, "dying", true, nil))

	b, err := m.bridgeFor("dying")
	require.NoError(t, err)
	eventually(t, "the bridge to declare send", func() bool { return b.HasCapability(CapSend) })

	_, err = m.sendOne(ctx, b, "dying", "c1", "hello", "", "")
	require.Error(t, err, "a send the bridge never answered must not succeed")

	msgs, _, err := m.Store().Page(ctx, "dying", "c1", 0, 10)
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, chat.StatusFailed, msgs[0].Status, "the message stays, marked as not sent")
}

// A bridge that says the same thing more than once, as they do on reconnect.
const repeatingScript = `#!/bin/sh
echo '{"event":"ready","protocol":1,"capabilities":["send"]}'
echo '{"event":"state","state":"connected"}'
echo '{"event":"chat","chat":{"id":"c1","name":"Ada","lastTs":1000,"lastText":"hi"}}'
echo '{"event":"message","message":{"id":"m1","chatId":"c1","ts":1000,"text":"hi","kind":"text"}}'
echo '{"event":"message","message":{"id":"m1","chatId":"c1","ts":1000,"text":"hi","kind":"text"}}'
echo '{"event":"messages","messages":[{"id":"m1","chatId":"c1","ts":1000,"text":"hi","kind":"text"},{"id":"m2","chatId":"c1","ts":2000,"text":"there","kind":"text"}]}'
echo '{"event":"message","message":{"id":"m3","chatId":"c1","ts":3000,"text":"done","kind":"text"}}'
cat >/dev/null
`

// Unread counts messages, not deliveries: three messages arriving five times
// between them are three unread.
func TestRedeliveredMessagesAreCountedOnce(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "repeat", "", repeatingScript)

	m := newTestManager(t, root)
	ctx := context.Background()
	require.NoError(t, m.SetEnabled(ctx, "repeat", true, nil))

	// Waited for on the conversation rather than the message: the count moves
	// a moment after the message itself is stored.
	eventually(t, "the last message to reach the conversation", func() bool {
		c, err := m.Store().ChatByID(ctx, "repeat", "c1")
		return err == nil && c.LastTS == 3000
	})

	c, err := m.Store().ChatByID(ctx, "repeat", "c1")
	require.NoError(t, err)
	assert.Equal(t, 3, c.Unread)
}

// The state pushed to an open window holds the same conversations chat.chats
// answers with: a provider switched off keeps its history, but out of sight.
func TestStateLeavesOutSwitchedOffProviders(t *testing.T) {
	m := newTestManager(t, t.TempDir())
	ctx := context.Background()

	require.NoError(t, m.Store().UpsertChat(ctx, chat.Chat{Provider: "on", ID: "a", Name: "A", LastTS: 100, Unread: 1}))
	require.NoError(t, m.Store().UpsertChat(ctx, chat.Chat{Provider: "off", ID: "b", Name: "B", LastTS: 200, Unread: 4}))
	switchOn(m, "on")

	state := m.GetState()
	require.Len(t, state.Chats, 1)
	assert.Equal(t, "on", state.Chats[0].Provider)
}

// A window closing while a broadcast is on its way used to close the channel
// the broadcast was about to send on, which panics and takes the manager down.
func TestUnsubscribingDuringBroadcastsIsSafe(t *testing.T) {
	m := newTestManager(t, t.TempDir())

	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
				m.markDirty()
				time.Sleep(time.Millisecond)
			}
		}
	}()

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ch := m.Subscribe("client")
		m.UnsubscribeChannel("client", ch)
		m.Subscribe("client")
		m.Unsubscribe("client")
	}

	close(stop)
	<-done
}

// Ending one stream must not end the subscription that replaced it.
func TestUnsubscribeChannelLeavesANewerSubscription(t *testing.T) {
	m := newTestManager(t, t.TempDir())

	first := m.Subscribe("client")
	second := m.Subscribe("client")
	m.UnsubscribeChannel("client", first)

	current, ok := m.subscribers.Load("client")
	require.True(t, ok, "the newer subscription is still there")
	assert.Equal(t, second, current)

	m.UnsubscribeChannel("client", second)
	_, ok = m.subscribers.Load("client")
	assert.False(t, ok)
}

// A protocol tap shows every call, but not what was typed to sign in.
func TestTapWithholdsSignInValues(t *testing.T) {
	payload := []byte(`{"id":4,"method":"authSubmit","params":{"values":{"password":"hunter2"}}}`)
	line := tapLineFor(4, MethodAuthSubmit, payload)
	assert.NotContains(t, line, "hunter2")
	assert.Contains(t, line, `"method":"authSubmit"`)

	other := []byte(`{"id":5,"method":"send","params":{"text":"hi"}}`)
	assert.Equal(t, string(other), tapLineFor(5, MethodSend, other))
}
