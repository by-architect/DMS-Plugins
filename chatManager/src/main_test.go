package main

import (
	"sync"
	"testing"
	"time"

	"dmschatmanager/internal/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Work on one lane happens in the order it arrived: two messages sent into one
// conversation must not overtake each other.
func TestLaneKeepsOrder(t *testing.T) {
	var l lanes
	var mu sync.Mutex
	var got []int
	var wg sync.WaitGroup

	for i := 0; i < 200; i++ {
		wg.Add(1)
		l.run("chat", func() {
			defer wg.Done()
			mu.Lock()
			got = append(got, i)
			mu.Unlock()
		})
	}
	wg.Wait()

	require.Len(t, got, 200)
	for i, v := range got {
		require.Equal(t, i, v, "lane ran out of order")
	}
}

// A slow request holds up its own lane only. This is the whole point: a photo
// being sent must not freeze switching to another conversation.
func TestSlowLaneDoesNotBlockAnother(t *testing.T) {
	var l lanes
	release := make(chan struct{})
	slowDone := make(chan struct{})
	fastDone := make(chan struct{})

	l.run("slow", func() {
		<-release
		close(slowDone)
	})
	l.run("fast", func() { close(fastDone) })

	select {
	case <-fastDone:
	case <-time.After(2 * time.Second):
		t.Fatal("the fast lane waited for the slow one")
	}

	close(release)
	select {
	case <-slowDone:
	case <-time.After(2 * time.Second):
		t.Fatal("the slow lane never finished")
	}
}

// Only what waits on a provider leaves the line; reads of the store keep their
// place in it.
func TestLaneFor(t *testing.T) {
	req := func(method string, params map[string]any) models.Request {
		return models.Request{ID: 7, Method: method, Params: params}
	}
	target := map[string]any{"provider": "wa", "chatId": "c1"}
	other := map[string]any{"provider": "wa", "chatId": "c2"}

	assert.Equal(t, laneFor(req("chat.send", target)), laneFor(req("chat.revoke", target)),
		"writes into one conversation share a lane")
	assert.NotEqual(t, laneFor(req("chat.send", target)), laneFor(req("chat.send", other)),
		"different conversations do not wait on each other")
	assert.Equal(t, laneFor(req("chat.setEnabled", target)), laneFor(req("chat.setProviderSettings", target)),
		"a provider being switched on is not overtaken by its own settings")

	for _, method := range []string{"chat.history", "chat.markRead", "chat.setFocus", "chat.chats", "chat.resolve"} {
		assert.Empty(t, laneFor(req(method, target)), "%s is answered in line", method)
	}
}
