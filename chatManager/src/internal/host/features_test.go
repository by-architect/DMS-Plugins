package host

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"dmschatmanager/internal/chat"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A provider with everything the contract has grown: older history on request,
// reactions, edits, typing, starting a conversation, and a mute it keeps in
// step with its own service. Each call answers the way a real bridge would --
// what it produces is sent before the reply that says it is done.
const featureScript = `#!/bin/sh
echo '{"event":"ready","protocol":1,"capabilities":["send","markRead","history","reactions","edit","typing","startChat","mute"]}'
echo '{"event":"state","state":"connected"}'
echo '{"event":"account","account":{"userId":"@me:example.org","verified":true}}'
echo '{"event":"chat","chat":{"id":"c1","name":"Ada","lastTs":5000,"lastText":"newest"}}'
echo '{"event":"messages","messages":[{"id":"mine","chatId":"c1","ts":4000,"text":"helo","kind":"text","fromMe":true,"senderId":"me"},{"id":"m5","chatId":"c1","ts":5000,"text":"newest","kind":"text","senderId":"ada"}]}'
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"history"'*)
      echo '{"event":"messages","backfill":true,"messages":[{"id":"m1","chatId":"c1","ts":1000,"text":"oldest","kind":"text","senderId":"ada"},{"id":"m2","chatId":"c1","ts":2000,"text":"older","kind":"text","senderId":"ada"}]}'
      echo "{\"id\":$id,\"ok\":true,\"result\":{\"hasMore\":false}}"
      ;;
    *'"method":"react"'*)
      echo "{\"id\":$id,\"ok\":true,\"result\":{\"reactionId\":\"r-mine\"}}"
      ;;
    *'"method":"typing"'*)
      echo '{"event":"typing","chatId":"c1","users":["Ada"]}'
      echo "{\"id\":$id,\"ok\":true}"
      ;;
    *'"method":"startChat"'*)
      echo "{\"id\":$id,\"ok\":true,\"result\":{\"chatId\":\"c2\",\"name\":\"Bea\"}}"
      ;;
    *'"method":"setMuted"'*)
      echo '{"event":"chat","chat":{"id":"c1","tags":["mutedAtService"]}}'
      echo "{\"id\":$id,\"ok\":true}"
      ;;
    *'"method":"shutdown"'*) echo "{\"id\":$id,\"ok\":true}"; exit 0 ;;
    *) echo "{\"id\":$id,\"ok\":true}" ;;
  esac
done
`

func startFeatureProvider(t *testing.T) (*Manager, context.Context) {
	t.Helper()

	root := t.TempDir()
	writePlugin(t, root, "feat", "", featureScript)

	m := newTestManager(t, root)
	ctx := context.Background()
	require.NoError(t, m.SetEnabled(ctx, "feat", true, nil))

	eventually(t, "the conversation and its messages to be stored", func() bool {
		page, _, err := m.Store().Page(ctx, "feat", "c1", 0, 50)
		return err == nil && len(page) == 2
	})
	return m, ctx
}

type historyPage struct {
	Messages []chat.Message `json:"messages"`
	HasMore  bool           `json:"hasMore"`
}

func historyRequest(t *testing.T, m *Manager, before int64) historyPage {
	t.Helper()
	resp := request(t, m, "chat.history", map[string]any{
		"provider": "feat", "chatId": "c1", "before": float64(before), "limit": float64(50),
	})
	require.Empty(t, resp.Error)
	require.NotNil(t, resp.Result)

	var page historyPage
	require.NoError(t, json.Unmarshal(*resp.Result, &page))
	return page
}

func ids(msgs []chat.Message) []string {
	out := make([]string, 0, len(msgs))
	for _, msg := range msgs {
		out = append(out, msg.ID)
	}
	return out
}

// Scrolling past what this device has stored asks the provider for what is
// older, waits for it, and answers with it -- rather than stopping where this
// device happened to start listening.
func TestOlderHistoryIsFetchedFromTheProvider(t *testing.T) {
	m, ctx := startFeatureProvider(t)

	before, err := m.Store().ChatByID(ctx, "feat", "c1")
	require.NoError(t, err)

	newest := historyRequest(t, m, 0)
	assert.Equal(t, []string{"mine", "m5"}, ids(newest.Messages))
	assert.True(t, newest.HasMore,
		"a provider that can fetch older messages should be offered the chance to")

	older := historyRequest(t, m, 4000)
	assert.Equal(t, []string{"m1", "m2"}, ids(older.Messages),
		"the page should hold what the provider fetched, not come back empty")
	assert.False(t, older.HasMore, "the provider said that is the beginning")

	after, err := m.Store().ChatByID(ctx, "feat", "c1")
	require.NoError(t, err)
	assert.Equal(t, before.Unread, after.Unread, "history paged in from the past was counted as unread")
	assert.EqualValues(t, 5000, after.LastTS, "history paged in moved the conversation's activity")

	again := historyRequest(t, m, 0)
	assert.False(t, again.HasMore,
		"once the provider has said there is nothing older, it should not be asked again")
}

func TestReactAndTakeItBack(t *testing.T) {
	m, ctx := startFeatureProvider(t)

	resp := request(t, m, "chat.react", map[string]any{
		"provider": "feat", "chatId": "c1", "messageId": "m5", "key": "👍",
	})
	require.Empty(t, resp.Error)

	page := historyRequest(t, m, 0)
	require.Len(t, page.Messages, 2)
	require.Len(t, page.Messages[1].Reactions, 1)
	assert.Equal(t, chat.ReactionSummary{Key: "👍", Count: 1, Mine: true}, page.Messages[1].Reactions[0])

	// Pressing it again is taking it back, not a second reaction.
	resp = request(t, m, "chat.react", map[string]any{
		"provider": "feat", "chatId": "c1", "messageId": "m5", "key": "👍",
	})
	require.Empty(t, resp.Error)
	mine, err := m.Store().MyReaction(ctx, "feat", "c1", "m5", "👍")
	require.NoError(t, err)
	assert.Equal(t, "r-mine", mine)

	resp = request(t, m, "chat.unreact", map[string]any{
		"provider": "feat", "chatId": "c1", "messageId": "m5", "key": "👍",
	})
	require.Empty(t, resp.Error)
	page = historyRequest(t, m, 0)
	assert.Empty(t, page.Messages[1].Reactions)
}

func TestEditOnlyOurOwnText(t *testing.T) {
	m, ctx := startFeatureProvider(t)

	resp := request(t, m, "chat.edit", map[string]any{
		"provider": "feat", "chatId": "c1", "messageId": "m5", "text": "rewritten",
	})
	assert.Contains(t, resp.Error, "own messages")

	resp = request(t, m, "chat.edit", map[string]any{
		"provider": "feat", "chatId": "c1", "messageId": "mine", "text": "   ",
	})
	assert.NotEmpty(t, resp.Error, "an edit emptying a message should be refused")

	resp = request(t, m, "chat.edit", map[string]any{
		"provider": "feat", "chatId": "c1", "messageId": "mine", "text": "hello",
	})
	require.Empty(t, resp.Error)

	msg, err := m.Store().MessageByID(ctx, "feat", "c1", "mine")
	require.NoError(t, err)
	assert.Equal(t, "hello", msg.Text)
	assert.Positive(t, msg.EditedTS)
}

func TestTypingIsRelayedAndNeverStored(t *testing.T) {
	m, _ := startFeatureProvider(t)

	var mu sync.Mutex
	var seen []string
	m.SetTypingHandler(func(provider, chatID string, users []string) {
		mu.Lock()
		defer mu.Unlock()
		seen = append(seen, provider+"/"+chatID+":"+strings.Join(users, ","))
	})

	resp := request(t, m, "chat.typing", map[string]any{
		"provider": "feat", "chatId": "c1", "typing": true,
	})
	require.Empty(t, resp.Error)

	eventually(t, "the provider's typing notice to be relayed", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(seen) == 1 && seen[0] == "feat/c1:Ada"
	})
}

func TestAccountIsRelayedUntouched(t *testing.T) {
	m, ctx := startFeatureProvider(t)

	eventually(t, "the account to reach the provider's status", func() bool {
		providers := m.Providers(ctx)
		return len(providers) == 1 && strings.Contains(string(providers[0].Account), "@me:example.org")
	})
}

func TestStartChatRecordsTheConversation(t *testing.T) {
	m, ctx := startFeatureProvider(t)

	resp := request(t, m, "chat.startChat", map[string]any{"provider": "feat", "handle": " @bea:example.org "})
	require.Empty(t, resp.Error)

	var started startChatResponse
	require.NoError(t, json.Unmarshal(*resp.Result, &started))
	assert.Equal(t, startChatResponse{ChatID: "c2", Name: "Bea"}, started)

	c, err := m.Store().ChatByID(ctx, "feat", "c2")
	require.NoError(t, err, "the conversation just started should open under its name")
	assert.Equal(t, "Bea", c.Name)
}

// A mute set here reaches the service, so the user's phone goes quiet too.
func TestMuteIsCarriedToTheService(t *testing.T) {
	m, ctx := startFeatureProvider(t)

	resp := request(t, m, "chat.setMuted", map[string]any{"provider": "feat", "chatId": "c1", "value": true})
	require.Empty(t, resp.Error)
	assert.True(t, m.Store().IsMuted(ctx, "feat", "c1"))

	eventually(t, "the provider to be told", func() bool {
		c, err := m.Store().ChatByID(ctx, "feat", "c1")
		return err == nil && containsTag(c.Tags, "mutedAtService")
	})
}

func containsTag(tags []string, want string) bool {
	for _, tag := range tags {
		if tag == want {
			return true
		}
	}
	return false
}
