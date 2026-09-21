package host

import (
	"context"
	"encoding/json"
	"net"
	"testing"

	"dmschatmanager/internal/chat"
	"dmschatmanager/internal/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A provider that has invitations: it announces one as a conversation tagged
// "invite" and answers both ways of responding to it.
const inviteScript = `#!/bin/sh
echo '{"event":"ready","protocol":1,"capabilities":["send","invites"]}'
echo '{"event":"state","state":"connected"}'
echo '{"event":"chat","chat":{"id":"room1","name":"Study Group","lastTs":5000,"lastText":"Ada invited you to this room","tags":["invite"]}}'
echo '{"event":"message","message":{"id":"room1/invite","chatId":"room1","ts":5000,"kind":"system","text":"Ada invited you to this room"}}'
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"shutdown"'*) echo "{\"id\":$id,\"ok\":true}"; exit 0 ;;
    *) echo "{\"id\":$id,\"ok\":true}" ;;
  esac
done
`

// request drives a chat.* method through the real handler and returns what the
// shell would have been sent back.
func request(t *testing.T, m *Manager, method string, params map[string]any) models.Response[json.RawMessage] {
	t.Helper()

	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		HandleRequest(models.NewConn(server), models.Request{ID: 1, Method: method, Params: params}, m)
	}()

	var out models.Response[json.RawMessage]
	require.NoError(t, json.NewDecoder(client).Decode(&out))
	<-done
	return out
}

// An invitation that is turned down is gone at the provider, so nothing will
// ever update the local row again. Left behind it would sit in the list
// offering to open a conversation that no longer exists.
func TestDeclineInviteRemovesTheConversation(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "inviter", "", inviteScript)

	m := newTestManager(t, root)
	ctx := context.Background()
	require.NoError(t, m.SetEnabled(ctx, "inviter", true, nil))

	eventually(t, "the invitation to be stored", func() bool {
		chats, err := m.Store().ChatsForProvider(ctx, "inviter", 10)
		return err == nil && len(chats) == 1
	})

	chats, err := m.Store().ChatsForProvider(ctx, "inviter", 10)
	require.NoError(t, err)
	assert.Contains(t, chats[0].Tags, "invite")
	assert.Positive(t, chats[0].LastTS,
		"an invitation with no activity of its own never reaches the conversation list")

	resp := request(t, m, "chat.declineInvite", map[string]any{
		"provider": "inviter", "chatId": "room1",
	})
	require.Empty(t, resp.Error)

	_, err = m.Store().ChatByID(ctx, "inviter", "room1")
	assert.Error(t, err, "the declined invitation is still in the store")
}

// Accepting keeps the conversation: it is a room now.
func TestAcceptInviteKeepsTheConversation(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "inviter", "", inviteScript)

	m := newTestManager(t, root)
	ctx := context.Background()
	require.NoError(t, m.SetEnabled(ctx, "inviter", true, nil))

	eventually(t, "the invitation to be stored", func() bool {
		chats, err := m.Store().ChatsForProvider(ctx, "inviter", 10)
		return err == nil && len(chats) == 1
	})

	resp := request(t, m, "chat.acceptInvite", map[string]any{
		"provider": "inviter", "chatId": "room1",
	})
	require.Empty(t, resp.Error)

	_, err := m.Store().ChatByID(ctx, "inviter", "room1")
	assert.NoError(t, err, "accepting an invitation must not remove the conversation")
}

// A provider with no notion of invitations is never asked to answer one: the
// UI hides the affordance, and the host refuses it rather than sending a call
// the bridge would have to reject.
func TestInviteNeedsTheCapability(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "echo", "", echoScript)

	m := newTestManager(t, root)
	ctx := context.Background()
	require.NoError(t, m.SetEnabled(ctx, "echo", true, nil))

	eventually(t, "the bridge to connect", func() bool {
		p := m.Providers(ctx)
		return len(p) == 1 && p[0].State == chat.StateConnected
	})

	resp := request(t, m, "chat.acceptInvite", map[string]any{
		"provider": "echo", "chatId": "c1",
	})
	assert.Contains(t, resp.Error, "invitations")
}

// An invitation answered on another device has to go here too: nothing will
// ever update the row again, and it cannot be answered a second time.
func TestChatGoneRemovesAnInvitationAnsweredElsewhere(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "inviter", "", inviteScript)

	m := newTestManager(t, root)
	ctx := context.Background()
	require.NoError(t, m.SetEnabled(ctx, "inviter", true, nil))

	eventually(t, "the invitation to be stored", func() bool {
		chats, err := m.Store().ChatsForProvider(ctx, "inviter", 10)
		return err == nil && len(chats) == 1
	})

	m.ingest(ingestEvent{provider: "inviter", frame: bridgeFrame{
		Event: EventChatGone, ChatID: "room1",
	}})

	_, err := m.Store().ChatByID(ctx, "inviter", "room1")
	assert.Error(t, err, "the withdrawn conversation is still in the store")
}
