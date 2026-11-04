package main

import (
	"encoding/json"
	"fmt"
	"sync"
)

// Calls are answered on lanes.
//
// The host's calls used to be answered strictly one at a time, in the order
// they were read. Anything slow -- a video being uploaded, a page of history
// being fetched and decrypted, a room being joined -- held up everything behind
// it: the read receipt for the conversation just opened, the attachment being
// opened, the typing notice, each waiting its turn for as long as the upload
// took, and the host gave up on some of them before it came.
//
// So each call goes on a lane, and lanes run alongside each other. Calls on the
// same lane keep their order, which is the order that matters: two messages
// sent into one room must arrive in the order they were written, an edit must
// not overtake the message it corrects, and signing in must not be overtaken by
// the settings it is configured with.

// lanes runs work in arrival order per lane, and lanes alongside each other.
type lanes struct {
	mu    sync.Mutex
	queue map[string][]func()
}

func (l *lanes) run(lane string, fn func()) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.queue == nil {
		l.queue = map[string][]func(){}
	}
	pending, busy := l.queue[lane]
	l.queue[lane] = append(pending, fn)
	if !busy {
		go l.drain(lane)
	}
}

// drain works through one lane until it is empty, then lets it go.
func (l *lanes) drain(lane string) {
	for {
		l.mu.Lock()
		pending := l.queue[lane]
		if len(pending) == 0 {
			delete(l.queue, lane)
			l.mu.Unlock()
			return
		}
		fn := pending[0]
		l.queue[lane] = pending[1:]
		l.mu.Unlock()

		fn()
	}
}

// laneFor names the lane a call is answered on.
func laneFor(c call) string {
	var params struct {
		ChatID string `json:"chatId"`
	}
	_ = json.Unmarshal(c.Params, &params)

	switch c.Method {
	case "configure", "login", "authSubmit", "verify", "logout":
		// The account itself: one thing at a time.
		return "account"
	case "send", "revoke", "react", "unreact", "edit", "acceptInvite", "declineInvite", "setMuted":
		// Everything that changes what a room says, in the order it was asked.
		return "room\x00" + params.ChatID
	case "markRead", "typing", "history":
		return c.Method + "\x00" + params.ChatID
	case "fetchMedia":
		// Each download is independent of every other.
		return fmt.Sprintf("fetch\x00%d", c.ID)
	case "startChat":
		return "start"
	}
	// Unknown methods are answered at once, and in order with each other.
	return "other"
}
