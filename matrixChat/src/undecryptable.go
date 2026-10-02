package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto"
	"maunium.net/go/mautrix/crypto/backup"
	"maunium.net/go/mautrix/crypto/cryptohelper"
	"maunium.net/go/mautrix/crypto/olm"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Messages that arrived but could not be decrypted, and trying them again.
//
// A message is encrypted with a room key its sender shares with each device
// separately, and a device that has not been given the key yet cannot read it.
// That is common, not exotic: every message a new device sees in its first
// sync, a sender whose phone shared the key a minute late, a device verified
// after the fact. mautrix waits half a minute for a key and then gives up --
// and since the sync position has moved on by then, nothing ever delivers the
// event again. Such a message used to vanish: the conversation simply had a
// hole in it, with no sign that anything had been said.
//
// So it is shown as waiting, under its own event id, and written down. It is
// tried again whenever its key might have turned up: when room keys arrive,
// after the recovery key restores the backup, and every so often, asking the
// key backup and this account's other devices for the keys still missing. When
// one decrypts, the real message goes out under the same id, and the host's
// upsert puts it where the placeholder was.

const (
	waitingText       = "Waiting for this message — it could not be decrypted yet"
	undecryptableText = "This message could not be decrypted"
	unshowableText    = "This message cannot be shown here"
	editedText        = "An earlier message was edited"

	// maxWaiting caps what is remembered. A new device without its keys sees
	// every encrypted message in its first sync fail, and the newest are the
	// ones worth the effort; an older one is let go, still saying it waits.
	maxWaiting = 1000

	// How often everything waiting is gone through, and how long after
	// starting the first time. The arrival of a key is what normally triggers
	// a retry; the timer is for keys that turn up without one, like a
	// backup filled in by another device.
	retryFirstPass = 30 * time.Second
	retryInterval  = 15 * time.Minute

	// retrySettle lets a burst of keys land before acting on it: restoring a
	// backup imports them by the thousand, each one announced on its own.
	retrySettle = 2 * time.Second

	// How much one pass asks for. Both are requests to the homeserver per
	// session, and the first pass on a new device can have hundreds; the
	// newest go first, and the rest on later passes.
	backupLookupsPerPass = 100
	keyRequestsPerPass   = 50
)

var (
	// errNoEncryption is an encrypted event met while encryption is not
	// running. Retried like a missing key: the next start may have it.
	errNoEncryption = errors.New("encryption is not working on this device")
	errRedacted     = errors.New("the message was deleted")
	errNotDecrypted = errors.New("the message could not be decrypted")
)

// worthRetrying reports whether a failure is one a key arriving later can cure.
//
// Anything else -- a key the sender withheld, a replayed message index, an
// event that claims the wrong room -- will fail the same way every time, and
// is said to be undecryptable rather than kept waiting forever.
func worthRetrying(err error) bool {
	return errors.Is(err, crypto.ErrNoSessionFound) ||
		// A key we hold, but starting later than this message. An earlier copy
		// of it -- from the backup, from another device -- opens it.
		errors.Is(err, olm.ErrUnknownMessageIndex) ||
		errors.Is(err, errNoEncryption)
}

// ---------------------------------------------------------------- the record

// waitingEvent is one message waiting for its key: enough to fetch it again,
// to know which key opens it, and to ask for that key.
type waitingEvent struct {
	RoomID    id.RoomID    `json:"roomId"`
	EventID   id.EventID   `json:"eventId"`
	SessionID id.SessionID `json:"sessionId"`
	SenderKey id.SenderKey `json:"senderKey,omitempty"`
	Sender    id.UserID    `json:"sender"`
	TS        int64        `json:"ts"`

	// Shown is whether a placeholder went to the host under this event's id.
	// An edit gets none, and whatever it turns out to be, there is then no
	// row to put right -- see recoveredFrom.
	Shown bool `json:"shown,omitempty"`
}

type waitingFile struct {
	// UserID is the account the list belongs to. It survives signing out --
	// the placeholders it fills in are still in the host's store, and a new
	// device verified with the recovery key can open most of them -- but not
	// signing in as somebody else.
	UserID string         `json:"userId"`
	Events []waitingEvent `json:"events"`
}

// waitingStore is the list, in memory and in undecryptable.json beside the
// session.
type waitingStore struct {
	mu      sync.Mutex
	writeMu sync.Mutex
	path    string
	user    id.UserID

	events   map[id.EventID]waitingEvent
	sessions map[id.SessionID]int
	dirty    bool

	// Kept per run, never written. fresh holds sessions whose key has arrived
	// since their events were last tried; tried, events already tried with a
	// key in hand that did not open them, so the timer does not fetch them
	// from the homeserver again every pass; requested, sessions already asked
	// for from this account's other devices.
	fresh     map[id.SessionID]bool
	tried     map[id.EventID]bool
	requested map[id.SessionID]bool
}

func newWaitingStore(path string, user id.UserID) *waitingStore {
	return &waitingStore{
		path:      path,
		user:      user,
		events:    map[id.EventID]waitingEvent{},
		sessions:  map[id.SessionID]int{},
		fresh:     map[id.SessionID]bool{},
		tried:     map[id.EventID]bool{},
		requested: map[id.SessionID]bool{},
	}
}

func waitingPath() (string, error) {
	dir, err := stateDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "undecryptable.json"), nil
}

// loadWaiting opens the list for an account, tolerating one that cannot be
// read: the worst case is placeholders nobody fills in.
func loadWaiting(user id.UserID) *waitingStore {
	path, err := waitingPath()
	if err != nil {
		logf("debug", "messages waiting for keys will not be remembered: %v", err)
		return newWaitingStore("", user)
	}

	store := newWaitingStore(path, user)
	data, err := os.ReadFile(path)
	if err != nil {
		return store
	}
	var file waitingFile
	if err := json.Unmarshal(data, &file); err != nil || id.UserID(file.UserID) != user {
		return store
	}
	for _, w := range file.Events {
		if w.RoomID != "" && w.EventID != "" && w.SessionID != "" {
			store.insertLocked(w)
		}
	}
	store.trimLocked()
	return store
}

func (s *waitingStore) insertLocked(w waitingEvent) {
	if old, ok := s.events[w.EventID]; ok {
		// A second failure of the same event: it was shown if either was.
		w.Shown = w.Shown || old.Shown
		s.removeLocked(old.EventID)
	}
	s.events[w.EventID] = w
	s.sessions[w.SessionID]++
}

func (s *waitingStore) removeLocked(eventID id.EventID) bool {
	w, ok := s.events[eventID]
	if !ok {
		return false
	}
	delete(s.events, eventID)
	delete(s.tried, eventID)
	if s.sessions[w.SessionID]--; s.sessions[w.SessionID] <= 0 {
		delete(s.sessions, w.SessionID)
		delete(s.fresh, w.SessionID)
	}
	return true
}

// trimLocked lets the oldest go once there are more than maxWaiting.
func (s *waitingStore) trimLocked() {
	for len(s.events) > maxWaiting {
		var oldest waitingEvent
		first := true
		for _, w := range s.events {
			if first || w.TS < oldest.TS || (w.TS == oldest.TS && w.EventID < oldest.EventID) {
				oldest, first = w, false
			}
		}
		s.removeLocked(oldest.EventID)
	}
}

// add remembers an event, and reports whether it is kept: one older than
// everything already waiting, on a full list, is not.
func (s *waitingStore) add(w waitingEvent) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.insertLocked(w)
	s.trimLocked()
	s.dirty = true
	_, kept := s.events[w.EventID]
	return kept
}

// forget drops an event, and reports whether it was still waiting. Whoever
// gets true is the one who says what became of it.
func (s *waitingStore) forget(eventID id.EventID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.removeLocked(eventID) {
		return false
	}
	s.dirty = true
	return true
}

// pending is everything waiting, oldest first.
func (s *waitingStore) pending() []waitingEvent {
	s.mu.Lock()
	out := make([]waitingEvent, 0, len(s.events))
	for _, w := range s.events {
		out = append(out, w)
	}
	s.mu.Unlock()

	sortByTime(out)
	return out
}

// markFresh notes that a session's key has arrived, and reports whether
// anything is waiting for it.
func (s *waitingStore) markFresh(sessionID id.SessionID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.sessions[sessionID] == 0 {
		return false
	}
	s.fresh[sessionID] = true
	return true
}

// takeFresh hands over the events whose key has arrived since they were last
// tried, and clears the mark.
func (s *waitingStore) takeFresh() []waitingEvent {
	s.mu.Lock()
	var out []waitingEvent
	for _, w := range s.events {
		if s.fresh[w.SessionID] {
			out = append(out, w)
		}
	}
	s.fresh = map[id.SessionID]bool{}
	s.mu.Unlock()

	sortByTime(out)
	return out
}

func (s *waitingStore) markTried(eventID id.EventID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.events[eventID]; ok {
		s.tried[eventID] = true
	}
}

func (s *waitingStore) wasTried(eventID id.EventID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tried[eventID]
}

func (s *waitingStore) wasRequested(sessionID id.SessionID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.requested[sessionID]
}

func (s *waitingStore) markRequested(sessionID id.SessionID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requested[sessionID] = true
}

// save writes the list if it changed, readable only by its owner, through a
// temporary file so an interrupted write cannot leave half a list.
func (s *waitingStore) save() {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()

	s.mu.Lock()
	if !s.dirty || s.path == "" {
		s.mu.Unlock()
		return
	}
	file := waitingFile{UserID: string(s.user), Events: make([]waitingEvent, 0, len(s.events))}
	for _, w := range s.events {
		file.Events = append(file.Events, w)
	}
	s.dirty = false
	s.mu.Unlock()

	sortByTime(file.Events)
	err := writePrivate(s.path, file)
	if err != nil {
		logf("debug", "could not write the messages waiting for keys: %v", err)
		s.mu.Lock()
		s.dirty = true
		s.mu.Unlock()
	}
}

func writePrivate(path string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func sortByTime(events []waitingEvent) {
	sort.Slice(events, func(i, j int) bool {
		if events[i].TS != events[j].TS {
			return events[i].TS < events[j].TS
		}
		return events[i].EventID < events[j].EventID
	})
}

// ---------------------------------------------------------------- the bridge's side

func (b *bridge) waitingList() *waitingStore {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.waiting
}

func (b *bridge) currentCrypto() *cryptohelper.CryptoHelper {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.crypto
}

func (b *bridge) saveWaiting() {
	if store := b.waitingList(); store != nil {
		store.save()
	}
}

// forgetWaiting drops an event that no longer needs its key: deleted, which
// the host has already been told.
func (b *bridge) forgetWaiting(eventID id.EventID) {
	if store := b.waitingList(); store != nil {
		store.forget(eventID)
	}
}

// watchDecryption has the encryption machinery tell the bridge what it could
// not decrypt, and when keys arrive.
//
// Both hooks are checked against the session they were set up for: mautrix's
// own wait for a key runs on in the background, and can report back after
// signing out has replaced everything it would report to.
func (b *bridge) watchDecryption(helper *cryptohelper.CryptoHelper) {
	helper.DecryptErrorCallback = func(evt *event.Event, err error) {
		if b.currentCrypto() == helper {
			b.noteUndecryptable(evt, err)
		}
	}
	helper.Machine().SessionReceived = func(_ context.Context, _ id.RoomID, sessionID id.SessionID, _ uint32) {
		if b.currentCrypto() == helper {
			b.keyArrived(sessionID)
		}
	}
}

// onEncryptedWithoutCrypto stands in for the crypto helper when encryption
// could not be started: nothing else handles encrypted events then, and they
// went by without a trace. Kept as waiting, they are tried on a later start
// that has encryption back.
func (b *bridge) onEncryptedWithoutCrypto(ctx context.Context, evt *event.Event) {
	b.noteUndecryptable(evt, errNoEncryption)
}

// noteUndecryptable shows an event that could not be decrypted as waiting,
// and remembers it to try again.
//
// The placeholder goes out as history -- the batch event, which the host
// stores without notifying, and which a system row would not notify for
// anyway -- held to the end of the response being read, so that a first sync
// full of them is one batch rather than a frame each.
func (b *bridge) noteUndecryptable(evt *event.Event, cause error) {
	if evt == nil || evt.ID == "" || evt.RoomID == "" {
		return
	}
	content, _ := evt.Content.Parsed.(*event.EncryptedEventContent)

	// The relation travels outside the encryption, which says what the event
	// is about to be without reading it.
	shown := true
	if content != nil && content.RelatesTo != nil {
		switch content.RelatesTo.Type {
		case event.RelAnnotation, event.RelReference:
			// A reaction, or a step of a verification or a poll: nothing this
			// bridge shows when it can read it, so nothing worth waiting for.
			return
		case event.RelReplace:
			// An edit lands on the message it corrects, which is already in
			// the conversation; a placeholder of its own would be a stray row.
			shown = false
		}
	}

	retry := worthRetrying(cause) && content != nil && content.SessionID != ""
	if !retry && !shown {
		return
	}

	w := waitingEvent{RoomID: evt.RoomID, EventID: evt.ID, Sender: evt.Sender, TS: evt.Timestamp, Shown: shown}
	if content != nil {
		w.SessionID = content.SessionID
		w.SenderKey = content.SenderKey
	}

	var msg messageObj
	if shown {
		msg = b.standIn(w, waitingText)
		// In the conversation, if only as a placeholder, so reading the room
		// acknowledges it like any other message.
		b.noteLastEvent(evt.RoomID, evt.ID, evt.Timestamp)
	}

	// Held from before the event is written down until its placeholder is
	// out or queued, so that a retry -- which can only find the event once it
	// is written down -- never sends the real message ahead of the
	// placeholder that would then overwrite it. See deliverRecovered.
	b.flushMu.Lock()
	defer b.flushMu.Unlock()

	kept := false
	if store := b.waitingList(); retry && store != nil {
		kept = store.add(w)
	}
	if !shown {
		return
	}
	if !kept {
		// Nothing will try it again, so it does not say that something will.
		msg.Text = undecryptableText
	}

	b.mu.Lock()
	if b.dispatching {
		b.history = append(b.history, msg)
		b.mu.Unlock()
		return
	}
	b.mu.Unlock()
	emitMessages([]messageObj{msg})
}

// standIn is the row that takes a message's place in the conversation while it
// cannot be shown: a system row, which the host neither counts as unread nor
// notifies for, under the event's own id so the real message replaces it.
func (b *bridge) standIn(w waitingEvent, text string) messageObj {
	return messageObj{
		ID:         string(w.EventID),
		ChatID:     string(w.RoomID),
		TS:         w.TS,
		FromMe:     w.Sender != "" && w.Sender == b.selfID(),
		SenderID:   string(w.Sender),
		SenderName: b.senderName(w.RoomID, w.Sender),
		Kind:       "system",
		Text:       text,
	}
}

// keyArrived is mautrix storing a room key, from wherever it came: shared by
// the sender, forwarded by another device, restored from the backup.
//
// Called from deep inside mautrix, so it only marks and wakes; the retry
// itself fetches from the homeserver, which is no work for the sync loop.
func (b *bridge) keyArrived(sessionID id.SessionID) {
	if store := b.waitingList(); store != nil && store.markFresh(sessionID) {
		b.wakeRetry(false)
	}
}

// wakeRetry asks for a retry pass now. A full one goes through everything
// waiting and asks for the keys still missing; otherwise only events whose key
// has just arrived are tried.
func (b *bridge) wakeRetry(full bool) {
	if full {
		b.mu.Lock()
		b.retryFull = true
		b.mu.Unlock()
	}
	select {
	case b.retryWake <- struct{}{}:
	default:
		// A pass is already due, and will see the flag.
	}
}

func (b *bridge) takeFullRetry() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	full := b.retryFull
	b.retryFull = false
	return full
}

func (b *bridge) firstSyncFinished() bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.firstSyncDone
}

// ---------------------------------------------------------------- retrying

// eventSource is the slice of the Matrix client that reading one event needs,
// and eventDecrypter the slice of the encryption machinery. Narrowed, like
// matrixSender, so retrying and the attachment-key lookup can be tested
// without a homeserver.
type eventSource interface {
	GetEvent(ctx context.Context, roomID id.RoomID, eventID id.EventID) (*event.Event, error)
}

type eventDecrypter interface {
	Decrypt(ctx context.Context, evt *event.Event) (*event.Event, error)
}

// sessionLookup is how a pass tells whether a key is here yet without asking
// the homeserver anything.
type sessionLookup interface {
	GetGroupSession(ctx context.Context, roomID id.RoomID, sessionID id.SessionID) (*crypto.InboundGroupSession, error)
}

// retryKit is everything a pass works with.
type retryKit struct {
	events   eventSource
	decrypt  eventDecrypter
	sessions sessionLookup

	// fetchKeys asks for keys still missing: the backup, other devices. Nil
	// when there is nobody to ask.
	fetchKeys func(ctx context.Context, missing []waitingEvent)
}

func (b *bridge) retryKitFor(client *mautrix.Client, helper *cryptohelper.CryptoHelper) retryKit {
	return retryKit{
		events:   client,
		decrypt:  helper,
		sessions: helper.Machine().CryptoStore,
		fetchKeys: func(ctx context.Context, missing []waitingEvent) {
			b.fetchMissingKeys(ctx, client, helper, missing)
		},
	}
}

// retryWaiting tries waiting events again for as long as the session it was
// started for lasts: when keys arrive, when asked to, and on a slow timer.
func (b *bridge) retryWaiting(ctx context.Context, kit retryKit) {
	timer := time.NewTimer(retryFirstPass)
	defer timer.Stop()

	for {
		full := false
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			if !b.firstSyncFinished() {
				// The first sync is still writing the list down; asking for
				// keys in the middle of it would ask for some that are on
				// their way.
				timer.Reset(retryFirstPass)
				continue
			}
			full = true
			timer.Reset(retryInterval)
		case <-b.retryWake:
			select {
			case <-time.After(retrySettle):
			case <-ctx.Done():
				return
			}
			full = b.takeFullRetry()
		}
		b.retryPass(ctx, kit, full)
	}
}

// retryPass tries again what has a chance: every event whose key has just
// arrived, and on a full pass every event whose key is here but that has not
// been tried with it yet -- after which the keys still missing are asked for.
func (b *bridge) retryPass(ctx context.Context, kit retryKit, full bool) {
	store := b.waitingList()
	if store == nil || ctx.Err() != nil {
		return
	}

	var attempt, missing, refused []waitingEvent
	if full {
		for _, w := range store.pending() {
			sess, err := kit.sessions.GetGroupSession(ctx, w.RoomID, w.SessionID)
			switch {
			case errors.Is(err, crypto.ErrGroupSessionWithheld):
				// The sender's device refused this one the key, and mautrix
				// will not take it from anywhere else afterwards.
				refused = append(refused, w)
			case err != nil:
				// The store could not be read this time; the next pass asks.
			case sess == nil:
				missing = append(missing, w)
			case !store.wasTried(w.EventID):
				attempt = append(attempt, w)
			}
		}
	}
	attempt = mergeWaiting(attempt, store.takeFresh())

	results := make([]retryResult, 0, len(refused)+len(attempt))
	for _, w := range refused {
		results = append(results, b.giveUp(w))
	}
	for _, w := range attempt {
		if ctx.Err() != nil {
			break
		}
		res, stop := b.retryOne(ctx, kit, w)
		if stop {
			break
		}
		results = append(results, res)
	}

	if recovered := b.deliverRecovered(results); len(recovered) > 0 {
		logf("info", "decrypted %d message(s) that had been waiting for their keys", len(recovered))
		// The rooms again, with where they have been read: the host counts
		// unread afresh from that, and a message that was a placeholder
		// until now was not counted when it arrived.
		seen := map[id.RoomID]bool{}
		var rooms []id.RoomID
		for _, w := range recovered {
			if !seen[w.RoomID] {
				seen[w.RoomID] = true
				rooms = append(rooms, w.RoomID)
			}
		}
		b.publishSome(rooms)
	}

	if full && kit.fetchKeys != nil && len(missing) > 0 && ctx.Err() == nil {
		kit.fetchKeys(ctx, missing)
	}
	store.save()
}

// mergeWaiting joins two lists of events without repeating one, oldest first:
// an edit retried after the message it edits would otherwise be overwritten
// by it.
func mergeWaiting(first, second []waitingEvent) []waitingEvent {
	seen := make(map[id.EventID]bool, len(first)+len(second))
	out := make([]waitingEvent, 0, len(first)+len(second))
	for _, w := range append(first, second...) {
		if !seen[w.EventID] {
			seen[w.EventID] = true
			out = append(out, w)
		}
	}
	sortByTime(out)
	return out
}

// retryResult is what became of one waiting event on a pass.
type retryResult struct {
	w waitingEvent
	// done is an event finished with -- decrypted, deleted, given up on --
	// and msgs what goes in its placeholder's place.
	done      bool
	recovered bool
	deleted   bool
	msgs      []messageObj
}

// giveUp is an event that will never be decrypted, saying so in place of the
// placeholder that promised otherwise.
func (b *bridge) giveUp(w waitingEvent) retryResult {
	res := retryResult{w: w, done: true}
	if w.Shown {
		res.msgs = []messageObj{b.standIn(w, undecryptableText)}
	}
	return res
}

// retryOne fetches a waiting event and tries its key on it. It also reports
// whether to stop the pass: a homeserver that cannot be reached for this event
// will not be for the next one either.
func (b *bridge) retryOne(ctx context.Context, kit retryKit, w waitingEvent) (retryResult, bool) {
	evt, err := fetchEvent(ctx, kit.events, kit.decrypt, w.RoomID, w.EventID)
	var httpErr mautrix.HTTPError
	switch {
	case err == nil:
		return retryResult{w: w, done: true, recovered: true, msgs: b.recoveredFrom(w, evt)}, false

	case errors.Is(err, errRedacted):
		// Deleted. Said again, since the deletion can have reached the host
		// before the placeholder did: mautrix waits half a minute for a key
		// before it reports a message it could not decrypt.
		return retryResult{w: w, done: true, deleted: true}, false

	case errors.Is(err, mautrix.MNotFound), errors.Is(err, mautrix.MForbidden):
		// Gone from the homeserver, or no longer ours to read.
		return b.giveUp(w), false

	case ctx.Err() != nil, errors.As(err, &httpErr):
		return retryResult{w: w}, true

	case worthRetrying(err):
		// The key we hold does not open it. Tried again when a better one
		// arrives, rather than fetched again every pass.
		if store := b.waitingList(); store != nil {
			store.markTried(w.EventID)
		}
		return retryResult{w: w}, false
	}
	return b.giveUp(w), false
}

// recoveredFrom turns a decrypted event into what replaces its placeholder.
func (b *bridge) recoveredFrom(w waitingEvent, evt *event.Event) []messageObj {
	var msg *messageObj
	edit := false
	if evt.Type == event.EventMessage || evt.Type == event.EventSticker {
		if content, ok := evt.Content.Parsed.(*event.MessageEventContent); ok {
			msg, edit = b.messageFor(evt, content)
		}
	}

	var out []messageObj
	if msg != nil {
		b.noteLastEvent(evt.RoomID, evt.ID, evt.Timestamp)
		out = append(out, *msg)
	}

	// The placeholder sits under this event's own id. When the message lands
	// somewhere else -- an edit lands on the message it corrects -- or turns
	// out to be nothing this bridge shows, the placeholder would go on
	// waiting for something that has come; it says what happened instead.
	if w.Shown && (msg == nil || edit) {
		row := b.standIn(w, unshowableText)
		row.Kind = "unsupported"
		if edit {
			row.Text, row.Kind = editedText, "system"
		}
		out = append(out, row)
	}
	return out
}

// deliverRecovered forgets the events a pass finished with and sends what
// takes their placeholders' place, reporting which were decrypted.
//
// Sent as history: the batch event, which the host stores without notifying.
// Some of these arrived days ago, and the rest already sat in the conversation
// as placeholders; none of it is news.
//
// All of it under flushMu, which placeholders are sent or held under and
// deletions are sent under. A placeholder sent after the message it stands for
// would put itself back over it, and a message filled in after its deletion
// would come back from it; forgetting an event and sending it in one step, under
// that lock, leaves room for neither.
func (b *bridge) deliverRecovered(results []retryResult) []waitingEvent {
	store := b.waitingList()
	if store == nil {
		return nil
	}

	b.flushMu.Lock()
	defer b.flushMu.Unlock()

	var recovered []waitingEvent
	var msgs, blank, deleted []messageObj
	for _, r := range results {
		if !r.done || !store.forget(r.w.EventID) {
			// Not finished with, or finished with elsewhere in the meantime:
			// deleted, which the host has been told already.
			continue
		}
		if r.deleted {
			if r.w.Shown {
				deleted = append(deleted, messageObj{ID: string(r.w.EventID), ChatID: string(r.w.RoomID)})
			}
			continue
		}
		if r.recovered {
			recovered = append(recovered, r.w)
		}
		for _, m := range r.msgs {
			// The host keeps a message's old text when a redelivery brings
			// none, which is right for a redelivery and wrong here: a photo
			// with no caption would keep the placeholder's words beneath it.
			if r.recovered && r.w.Shown && m.ID == string(r.w.EventID) && m.Text == "" {
				blank = append(blank, m)
			}
		}
		msgs = append(msgs, r.msgs...)
	}
	if len(msgs) == 0 && len(deleted) == 0 {
		return recovered
	}

	b.flushHeldLocked()
	// A deletion is the one thing that clears a row's text, and the message
	// that follows straight after fills the row in again -- with no text,
	// as it arrived. The host draws once a burst is over, so the deletion is
	// not what it shows.
	for _, m := range append(blank, deleted...) {
		emitEvent("deleted", map[string]any{"chatId": m.ChatID, "messageId": m.ID})
	}
	emitMessages(msgs)
	return recovered
}

// ---------------------------------------------------------------- fetching an event

// fetchEvent reads one event from the homeserver, decrypted when it was
// encrypted.
func fetchEvent(ctx context.Context, src eventSource, dec eventDecrypter, roomID id.RoomID, eventID id.EventID) (*event.Event, error) {
	evt, err := src.GetEvent(ctx, roomID, eventID)
	if err != nil {
		return nil, err
	}
	if evt.Unsigned.RedactedBecause != nil {
		return nil, errRedacted
	}
	if evt.RoomID == "" {
		evt.RoomID = roomID
	}
	// The sync parses content before handing an event over; a fetched one
	// arrives raw.
	if evt.Content.Parsed == nil {
		if err := evt.Content.ParseRaw(evt.Type); err != nil && !errors.Is(err, event.ErrUnsupportedContentType) {
			return nil, fmt.Errorf("unreadable message: %w", err)
		}
	}
	if evt.Type != event.EventEncrypted {
		return evt, nil
	}
	if dec == nil {
		return nil, fmt.Errorf("%w: %w", errNotDecrypted, errNoEncryption)
	}
	decrypted, err := dec.Decrypt(ctx, evt)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errNotDecrypted, err)
	}
	return decrypted, nil
}

// ---------------------------------------------------------------- asking for keys

// fetchMissingKeys asks for the keys still missing: from the key backup, one
// session at a time, once the recovery key has been entered on this device;
// then from this account's other devices. What either sends back arrives as a
// key like any other, and wakes the retry.
//
// Only our own devices are asked, and only once this one is verified. A
// device that will not share answers with a refusal -- another user's device
// always, one of ours while this one is unverified -- and mautrix keeps a
// refusal as the key being withheld, after which it will not take that key
// from anywhere, the backup included. Asking too early would lose a message
// that verifying would have recovered.
func (b *bridge) fetchMissingKeys(ctx context.Context, client *mautrix.Client, helper *cryptohelper.CryptoHelper, missing []waitingEvent) {
	store := b.waitingList()
	if store == nil {
		return
	}
	mach := helper.Machine()
	sessions := newestSessions(missing)

	restored := b.restoreFromBackup(ctx, client, mach, sessions)
	if !crossSigned(ctx, mach) {
		return
	}

	asked := 0
	for _, w := range sessions {
		if asked == keyRequestsPerPass || ctx.Err() != nil {
			break
		}
		if restored[w.SessionID] || store.wasRequested(w.SessionID) {
			continue
		}
		users := map[id.UserID][]id.DeviceID{client.UserID: {"*"}}
		if err := mach.SendRoomKeyRequest(ctx, w.RoomID, w.SenderKey, w.SessionID, "", users); err != nil {
			logf("debug", "could not ask for a missing room key: %v", err)
			break
		}
		store.markRequested(w.SessionID)
		asked++
	}
	if asked > 0 {
		logf("debug", "asked this account's other devices for %d missing room key(s)", asked)
	}
}

// crossSigned reports whether this device is signed by the account's
// cross-signing keys -- what verifying with the recovery key does, and what
// the account's other devices look for before they share a key with it.
func crossSigned(ctx context.Context, mach *crypto.OlmMachine) bool {
	own := mach.OwnIdentity()
	// Marked as verified by itself, which settles nothing for anyone else.
	own.Trust = id.TrustStateUnset
	trust, err := mach.ResolveTrustContext(ctx, own)
	return err == nil && trust >= id.TrustStateCrossSignedTOFU
}

// newestSessions is one event per session, newest first: the order keys are
// worth asking for in.
func newestSessions(events []waitingEvent) []waitingEvent {
	sorted := append([]waitingEvent(nil), events...)
	sortByTime(sorted)

	seen := map[id.SessionID]bool{}
	var out []waitingEvent
	for i := len(sorted) - 1; i >= 0; i-- {
		if w := sorted[i]; !seen[w.SessionID] {
			seen[w.SessionID] = true
			out = append(out, w)
		}
	}
	return out
}

// restoreFromBackup looks missing sessions up in the key backup, one at a
// time, and reports which came back.
//
// Restoring the whole backup happens once, when the recovery key is entered.
// A key the backup only gains later -- another device of ours uploading what
// it was sent -- would otherwise never reach this one.
func (b *bridge) restoreFromBackup(ctx context.Context, client *mautrix.Client, mach *crypto.OlmMachine, sessions []waitingEvent) map[id.SessionID]bool {
	key := storedBackupKey(ctx, mach)
	if key == nil {
		return nil
	}
	info, err := mach.GetAndVerifyLatestKeyBackupVersion(ctx, key)
	if err != nil || info == nil {
		logf("debug", "the key backup cannot be used: %v", err)
		return nil
	}

	restored := map[id.SessionID]bool{}
	for i, w := range sessions {
		if i == backupLookupsPerPass || ctx.Err() != nil {
			break
		}
		data, err := client.GetKeyBackupForRoomAndSession(ctx, info.Version, w.RoomID, w.SessionID)
		if errors.Is(err, mautrix.MNotFound) {
			// Not backed up, or not yet.
			continue
		}
		if err != nil {
			logf("debug", "could not look a room key up in the backup: %v", err)
			break
		}
		session, err := data.SessionData.Decrypt(key)
		if err != nil {
			continue
		}
		if _, err := mach.ImportRoomKeyFromBackup(ctx, info.Version, w.RoomID, w.SessionID, session); err != nil {
			continue
		}
		restored[w.SessionID] = true
	}
	if len(restored) > 0 {
		logf("info", "restored %d room key(s) from the key backup", len(restored))
	}
	return restored
}

// keepBackupKey stores the backup key in the encryption store, encrypted like
// the room keys beside it, so the backup can still be asked after a restart --
// see restoreFromBackup. The recovery key that unlocked it is not kept.
func keepBackupKey(ctx context.Context, mach *crypto.OlmMachine, raw []byte) {
	if err := mach.CryptoStore.PutSecret(ctx, id.SecretMegolmBackupV1, base64.RawStdEncoding.EncodeToString(raw)); err != nil {
		logf("debug", "could not keep the backup key: %v", err)
	}
}

func storedBackupKey(ctx context.Context, mach *crypto.OlmMachine) *backup.MegolmBackupKey {
	secret, err := mach.CryptoStore.GetSecret(ctx, id.SecretMegolmBackupV1)
	if err != nil || secret == "" {
		return nil
	}
	raw, err := base64.RawStdEncoding.DecodeString(strings.TrimRight(secret, "="))
	if err != nil {
		return nil
	}
	key, err := backup.MegolmBackupKeyFromBytes(raw)
	if err != nil {
		return nil
	}
	return key
}
