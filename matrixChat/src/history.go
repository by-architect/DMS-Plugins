package main

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto/cryptohelper"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Older history, fetched from the homeserver.
//
// A room used to show what had arrived since this device signed in, and not a
// message more: scrolling to the top of a conversation ended where the device
// happened to start listening. Matrix keeps the whole timeline, and /messages
// pages back through it; this is that, in two shapes.
//
//   - On request. The host asks for messages older than the oldest it has
//     stored, and waits: this finds where in the timeline that is, pages back
//     from there, and sends what it found as a backfill batch -- stored where
//     it belongs, never counted as unread -- before answering.
//   - On its own. A sync after time away is "limited": the homeserver sends a
//     room's newest fifty events and a token, and everything between those and
//     the last event this device had is simply not in it. Those are fetched
//     straight away, so a busy room does not quietly lose what was said while
//     the shell was off.
//
// Encrypted history is decrypted with whatever keys this device has. What it
// has no key for yet is shown as waiting, and written down to be tried again,
// exactly like a message the sync could not decrypt -- so verifying the device
// with the recovery key later fills those in too.

const (
	// One page of /messages, and how many one request may walk through to
	// find what was asked for. A page can be mostly reactions or messages the
	// host already has, so one is not always enough.
	historyPageSize = 100
	historyMaxPages = 5

	// historyBudget bounds one request, under the host's own wait for it.
	historyBudget = 20 * time.Second

	// A gap is walked further, in the background, since nothing waits on it.
	gapMaxPages = 10
	gapBudget   = 2 * time.Minute

	// gapWorkers is how many rooms' gaps are filled at once. Coming back from
	// a week away, every busy room is a gap, and walking them all at once is
	// a burst of requests the homeserver would rate-limit.
	gapWorkers = 2
)

// gapSlots holds a place for each gap being filled.
var gapSlots = make(chan struct{}, gapWorkers)

// historyFilter asks for what a conversation shows, and lazily for the members
// who sent it -- their names as they were then.
var historyFilter = &mautrix.FilterPart{
	LazyLoadMembers: true,
	Types: []event.Type{
		event.EventMessage, event.EventEncrypted, event.EventSticker, event.EventReaction,
	},
}

// historyClient is the slice of the Matrix client paging history needs,
// narrowed like matrixSender so it can be tested without a homeserver.
type historyClient interface {
	Messages(ctx context.Context, roomID id.RoomID, from, to string, dir mautrix.Direction, filter *mautrix.FilterPart, limit int) (*mautrix.RespMessages, error)
	TimestampToEvent(ctx context.Context, roomID id.RoomID, timestamp time.Time, dir mautrix.Direction) (*mautrix.RespTimestampToEvent, error)
	Context(ctx context.Context, roomID id.RoomID, eventID id.EventID, filter *mautrix.FilterPart, limit int) (*mautrix.RespContext, error)
}

// ---------------------------------------------------------------- on request

// handleHistory fetches messages older than before, sends them, and answers
// whether there is more before those.
func (b *bridge) handleHistory(ctx context.Context, c call) {
	var params struct {
		ChatID string `json:"chatId"`
		Before int64  `json:"before"`
		Limit  int    `json:"limit"`
	}
	_ = json.Unmarshal(c.Params, &params)
	if params.ChatID == "" {
		fail(c.ID, "bad_params", "chatId is required")
		return
	}

	// The beginning, once reached, is the answer whether or not the homeserver
	// can be asked right now.
	roomID := id.RoomID(params.ChatID)
	if b.historyEnded(roomID) {
		ok(c.ID, map[string]any{"hasMore": false})
		return
	}

	client := b.getClient()
	if client == nil {
		fail(c.ID, "not_connected", "Matrix is not connected")
		return
	}

	limit := params.Limit
	if limit <= 0 || limit > historyPageSize {
		limit = 50
	}
	before := params.Before
	if before <= 0 {
		before = time.Now().UnixMilli()
	}

	ctx, cancel := context.WithTimeout(ctx, historyBudget)
	defer cancel()

	more, err := b.backfill(ctx, client, roomID, before, limit)
	b.persistRooms()
	if err != nil {
		fail(c.ID, "history_failed", "%s", serverMessage(err, "could not fetch older messages"))
		return
	}
	ok(c.ID, map[string]any{"hasMore": more})
}

// backfill pages back through a room from before until it has found limit
// messages, or the beginning, or the end of what one request may walk. Reports
// whether there is anything older left.
func (b *bridge) backfill(ctx context.Context, client historyClient, roomID id.RoomID, before int64, limit int) (bool, error) {
	token, anchor, seed, err := b.historyStart(ctx, client, roomID, before)
	if errors.Is(err, errNothingBefore) {
		// The homeserver says no event comes before that moment: this is the
		// beginning, and walking the whole room back to find so would only
		// prove it slowly.
		b.endHistory(roomID)
		return false, nil
	}

	events := seed
	var members []*event.Event
	shown := countShown(seed)
	oldest := anchor
	ended := false

	for page := 0; page < historyMaxPages && shown < limit; page++ {
		resp, err := client.Messages(ctx, roomID, token, "", mautrix.DirectionBackward, historyFilter, historyPageSize)
		if err != nil {
			if len(events) > 0 {
				// What was found still goes out; the next request carries on.
				break
			}
			return true, err
		}

		members = append(members, resp.State...)
		for _, evt := range resp.Chunk {
			if evt == nil {
				continue
			}
			// How far back the walk has got, counting what it passed: the
			// next request carries on from behind all of it.
			if evt.Timestamp > 0 && (oldest == 0 || evt.Timestamp < oldest) {
				oldest = evt.Timestamp
			}
			// A walk from the newest event passes everything the host already
			// has on its way back; none of that is what was asked for.
			if evt.Timestamp > before {
				continue
			}
			events = append(events, evt)
			if isShown(evt.Type) {
				shown++
			}
		}

		// An empty page is not the beginning -- everything in it may have
		// been filtered out -- but a page with no token after it is, or as
		// far back as this account may see.
		if resp.End == "" || resp.End == token {
			ended = true
			break
		}
		token = resp.End
	}

	if ended {
		b.endHistory(roomID)
	} else {
		b.advanceHistory(roomID, token, oldest)
	}
	b.deliverHistory(ctx, roomID, events, members, true)
	return !ended, nil
}

// historyStart finds where paging back from before begins: the token to page
// from, the time it lies behind, and any events the search itself turned up,
// which lie behind that token and so would never be paged to.
//
// Three ways, best first. Where the last request stopped, when that is where
// this one starts -- the ordinary case, scrolling up and up. Otherwise the
// moment looked up with /timestamp_to_event. And on a homeserver without that,
// the nearest token this device holds, or failing everything the newest event,
// walking back past whatever is already stored.
func (b *bridge) historyStart(ctx context.Context, client historyClient, roomID id.RoomID, before int64) (string, int64, []*event.Event, error) {
	b.mu.RLock()
	var token string
	var tokenTS int64
	if info := b.rooms[roomID]; info != nil {
		token, tokenTS = info.BackfillToken, info.BackfillTS
	}
	b.mu.RUnlock()

	if token != "" && tokenTS > 0 && tokenTS <= before {
		return token, tokenTS, nil, nil
	}

	at, seed, err := tokenAt(ctx, client, roomID, before)
	switch {
	case err == nil:
		return at, before, seed, nil
	case errors.Is(err, errNothingBefore):
		return "", 0, nil, err
	}
	logf("debug", "could not find %s at %d, walking back to it instead: %v", roomID, before, err)
	return token, tokenTS, nil, nil
}

// errNothingBefore is the homeserver finding no event at all before a moment.
var errNothingBefore = errors.New("no event comes before that moment")

// tokenAt finds a pagination token just before a moment in a room's timeline.
//
// /timestamp_to_event names the event nearest the moment, and /context around
// it gives the token. The context is asked for one event, which servers put
// after the one found; the found event itself, and anything a server put before
// it, are returned so they are not skipped.
func tokenAt(ctx context.Context, client historyClient, roomID id.RoomID, before int64) (string, []*event.Event, error) {
	found, err := client.TimestampToEvent(ctx, roomID, time.UnixMilli(before), mautrix.DirectionBackward)
	if errors.Is(err, mautrix.MNotFound) {
		// Distinct from a homeserver without the endpoint, which says
		// M_UNRECOGNIZED: this one looked, and there is nothing.
		return "", nil, errNothingBefore
	}
	if err != nil {
		return "", nil, err
	}
	around, err := client.Context(ctx, roomID, found.EventID, historyFilter, 1)
	if err != nil {
		return "", nil, err
	}
	if around.Start == "" {
		return "", nil, errors.New("the homeserver gave no position to page back from")
	}

	var seed []*event.Event
	for _, evt := range append([]*event.Event{around.Event}, around.EventsBefore...) {
		if evt != nil && evt.Timestamp <= before && isHistoryType(evt.Type) {
			seed = append(seed, evt)
		}
	}
	return around.Start, seed, nil
}

func isHistoryType(t event.Type) bool {
	switch t {
	case event.EventMessage, event.EventEncrypted, event.EventSticker, event.EventReaction:
		return true
	}
	return false
}

// isShown is whether an event is a row in the conversation, which is what the
// host's limit counts. A reaction is not; an encrypted event usually is.
func isShown(t event.Type) bool {
	switch t {
	case event.EventMessage, event.EventEncrypted, event.EventSticker:
		return true
	}
	return false
}

func countShown(events []*event.Event) int {
	n := 0
	for _, evt := range events {
		if evt != nil && isShown(evt.Type) {
			n++
		}
	}
	return n
}

// advanceHistory remembers how far back a walk got, so the next request
// carries on from there. Never forwards: a walk from the newest event that
// stopped short must not replace a token that had got further.
func (b *bridge) advanceHistory(roomID id.RoomID, token string, ts int64) {
	if token == "" {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()

	info := b.roomLocked(roomID)
	if info.BackfillToken != "" && info.BackfillTS > 0 && (ts == 0 || ts > info.BackfillTS) {
		return
	}
	info.BackfillToken, info.BackfillTS = token, ts
}

// endHistory records that a room's beginning has been reached.
func (b *bridge) endHistory(roomID id.RoomID) {
	b.mu.Lock()
	defer b.mu.Unlock()

	info := b.roomLocked(roomID)
	info.BackfillDone = true
	info.BackfillToken, info.BackfillTS = "", 0
}

func (b *bridge) historyEnded(roomID id.RoomID) bool {
	b.mu.RLock()
	defer b.mu.RUnlock()

	info := b.rooms[roomID]
	return info != nil && info.BackfillDone
}

// ---------------------------------------------------------------- the gaps

// gapJob is a stretch of a room's timeline a limited sync left out: it sent
// the newest events and a token to page back from, and everything between that
// and the newest event this device already had was not in it.
type gapJob struct {
	roomID id.RoomID
	token  string
	since  int64
}

// notePagination reads what a sync response says about paging, before it is
// processed: where each room seen for the first time begins -- the token the
// first walk back starts from -- and which rooms it skipped events in.
//
// Before, because processing moves each room's newest event on, and that is
// the point a gap has to be filled back to.
func (b *bridge) notePagination(resp *mautrix.RespSync, since string) []gapJob {
	var gaps []gapJob

	b.mu.Lock()
	defer b.mu.Unlock()

	for roomID, joined := range resp.Rooms.Join {
		if joined == nil || joined.Timeline.PrevBatch == "" {
			continue
		}
		timeline := joined.Timeline
		info := b.roomLocked(roomID)

		if info.BackfillToken == "" && !info.BackfillDone {
			info.BackfillToken, info.BackfillTS = timeline.PrevBatch, oldestOf(timeline.Events)
		}
		// Not on an initial sync: that one is limited by its nature, and what
		// it left out is history, fetched when it is scrolled to.
		if since != "" && timeline.Limited && info.LastEventTS > 0 {
			gaps = append(gaps, gapJob{roomID: roomID, token: timeline.PrevBatch, since: info.LastEventTS})
		}
	}
	return gaps
}

func oldestOf(events []*event.Event) int64 {
	var oldest int64
	for _, evt := range events {
		if evt != nil && evt.Timestamp > 0 && (oldest == 0 || evt.Timestamp < oldest) {
			oldest = evt.Timestamp
		}
	}
	return oldest
}

// fillGap fetches what a limited sync left out of a room.
//
// Sent as an ordinary batch: these arrived while the shell was away, so they
// count as unread where they are newer than the read position, but none of
// them notifies -- the newest fifty already said what there was to say.
func (b *bridge) fillGap(job gapJob) {
	client := b.getClient()
	if client == nil || !b.claimGap(job.roomID) {
		return
	}
	defer b.releaseGap(job.roomID)

	gapSlots <- struct{}{}
	defer func() { <-gapSlots }()

	// Signed out, or signed in again, while it waited its turn.
	if b.getClient() != client {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), gapBudget)
	defer cancel()

	n, err := b.walkGap(ctx, client, job)
	if err != nil {
		logf("debug", "could not fetch what %s missed: %v", job.roomID, err)
	}
	if n > 0 {
		logf("info", "fetched %d message(s) sent to %s while this device was away", n, job.roomID)
	}
}

// walkGap pages back from the gap's token until it reaches what the device
// already had, and delivers what lay between.
func (b *bridge) walkGap(ctx context.Context, client historyClient, job gapJob) (int, error) {
	var events, members []*event.Event
	token := job.token
	var walkErr error

	for page := 0; page < gapMaxPages; page++ {
		resp, err := client.Messages(ctx, job.roomID, token, "", mautrix.DirectionBackward, historyFilter, historyPageSize)
		if err != nil {
			walkErr = err
			break
		}
		members = append(members, resp.State...)

		reached := false
		for _, evt := range resp.Chunk {
			if evt == nil {
				continue
			}
			if evt.Timestamp <= job.since {
				reached = true
				continue
			}
			events = append(events, evt)
		}
		if reached || resp.End == "" || resp.End == token {
			break
		}
		token = resp.End
	}
	return b.deliverHistory(ctx, job.roomID, events, members, false), walkErr
}

func (b *bridge) claimGap(roomID id.RoomID) bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.gapFills[roomID] {
		return false
	}
	if b.gapFills == nil {
		b.gapFills = map[id.RoomID]bool{}
	}
	b.gapFills[roomID] = true
	return true
}

func (b *bridge) releaseGap(roomID id.RoomID) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.gapFills, roomID)
}

// ---------------------------------------------------------------- delivering

// deliverHistory turns paged events into what the host stores, and sends it:
// messages oldest first, then the reactions to them. Reports how many rows went
// out.
//
// backfill marks it as older history fetched on request, which the host never
// counts as unread; a gap is not that, since what it held arrived while nobody
// was looking.
func (b *bridge) deliverHistory(ctx context.Context, roomID id.RoomID, events, members []*event.Event, backfill bool) int {
	// Oldest first, as the timeline reads: an edit then lands after the
	// message it corrects when both are in one batch.
	sort.SliceStable(events, func(i, j int) bool { return events[i].Timestamp < events[j].Timestamp })

	helper := b.currentCrypto()
	names := memberNames(members)
	b.rememberNames(roomID, names)

	var msgs []messageObj
	var reactions []reactionObj
	var waiting []waitingEvent
	seen := map[id.EventID]bool{}

	for _, evt := range events {
		if evt == nil || evt.ID == "" || seen[evt.ID] {
			continue
		}
		seen[evt.ID] = true
		evt.RoomID = roomID

		if evt.Unsigned.RedactedBecause != nil {
			if row := b.tombstone(evt); row != nil {
				msgs = append(msgs, *row)
			}
			continue
		}
		if evt.Content.Parsed == nil {
			if err := evt.Content.ParseRaw(evt.Type); err != nil && !errors.Is(err, event.ErrContentAlreadyParsed) {
				continue
			}
		}

		if evt.Type == event.EventEncrypted {
			decrypted, err := decryptHistory(ctx, helper, evt)
			if err != nil {
				w, shown, retry, keep := classifyUndecryptable(evt, err)
				if !keep {
					continue
				}
				if retry {
					waiting = append(waiting, w)
				}
				if shown {
					msgs = append(msgs, b.standIn(w, waitingText))
				}
				continue
			}
			evt = decrypted
			evt.RoomID = roomID
		}

		switch evt.Type {
		case event.EventMessage, event.EventSticker:
			content, ok := evt.Content.Parsed.(*event.MessageEventContent)
			if !ok {
				continue
			}
			if msg, _ := b.messageFor(evt, content); msg != nil {
				msgs = append(msgs, *msg)
			}
		case event.EventReaction:
			if r := b.reactionFor(evt); r != nil {
				reactions = append(reactions, *r)
			}
		}
	}

	nameSenders(msgs, reactions, names)

	// Under the lock a decrypted message goes out under: a placeholder sent
	// after the retry that replaces it would put itself back over the message.
	// See deliverRecovered.
	b.flushMu.Lock()
	defer b.flushMu.Unlock()

	kept := map[id.EventID]bool{}
	if store := b.waitingList(); store != nil && len(waiting) > 0 {
		for _, w := range waiting {
			if store.add(w) {
				kept[w.EventID] = true
			}
		}
		store.save()
	}
	for i := range msgs {
		// Nothing will try it again, so it does not say that something will.
		if msgs[i].Kind == "system" && msgs[i].Text == waitingText && !kept[id.EventID(msgs[i].ID)] {
			msgs[i].Text = undecryptableText
		}
	}

	b.flushHeldLocked()
	emitHistory(msgs, backfill)
	emitReactions(reactions)
	return len(msgs)
}

// decryptHistory decrypts one event from a page of history.
func decryptHistory(ctx context.Context, helper *cryptohelper.CryptoHelper, evt *event.Event) (*event.Event, error) {
	if helper == nil {
		return nil, errNoEncryption
	}
	return helper.Decrypt(ctx, evt)
}

// tombstone is the row for a message that was deleted before it was paged in.
//
// Only for messages that were sent in the clear. An encrypted event loses
// everything when it is deleted, including whether it was a message or a
// reaction, and a "deleted message" row for a reaction taken back would be a
// row about nothing.
func (b *bridge) tombstone(evt *event.Event) *messageObj {
	if evt.Type != event.EventMessage && evt.Type != event.EventSticker {
		return nil
	}
	return &messageObj{
		ID:         string(evt.ID),
		ChatID:     string(evt.RoomID),
		TS:         evt.Timestamp,
		FromMe:     evt.Sender == b.selfID(),
		SenderID:   string(evt.Sender),
		SenderName: b.senderName(evt.RoomID, evt.Sender),
		Kind:       "deleted",
	}
}

// memberNames reads display names out of the member state a page of history
// came with: what people were called when they wrote it.
func memberNames(members []*event.Event) map[id.UserID]string {
	names := map[id.UserID]string{}
	for _, evt := range members {
		if evt == nil || evt.Type != event.StateMember {
			continue
		}
		if evt.Content.Parsed == nil {
			_ = evt.Content.ParseRaw(evt.Type)
		}
		content, ok := evt.Content.Parsed.(*event.MemberEventContent)
		if !ok {
			continue
		}
		if name := strings.TrimSpace(content.Displayname); name != "" {
			names[id.UserID(evt.GetStateKey())] = name
		}
	}
	return names
}

// nameSenders names the senders this device had no name for -- people who have
// since left the room, mostly -- from the member state the page came with.
//
// Only those: the room's own member list stays as it is now, so someone who
// left last year does not start naming the room.
func nameSenders(msgs []messageObj, reactions []reactionObj, names map[id.UserID]string) {
	if len(names) == 0 {
		return
	}
	for i := range msgs {
		if unnamed(msgs[i].SenderName, msgs[i].SenderID) {
			if name := names[id.UserID(msgs[i].SenderID)]; name != "" {
				msgs[i].SenderName = name
			}
		}
	}
	for i := range reactions {
		if unnamed(reactions[i].SenderName, reactions[i].SenderID) {
			if name := names[id.UserID(reactions[i].SenderID)]; name != "" {
				reactions[i].SenderName = name
			}
		}
	}
}

// unnamed is whether a sender's name is only what their account id was made
// into for want of one.
func unnamed(name, senderID string) bool {
	return name == senderID || name == fallbackName(id.UserID(senderID))
}

// rememberNames keeps the names a page of history came with as the answer to
// who those senders are, so naming them asks the homeserver nothing more --
// and someone who has left is named without joining the member list, where
// they would start naming the room.
func (b *bridge) rememberNames(roomID id.RoomID, names map[id.UserID]string) {
	if len(names) == 0 {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.lookedUpNames == nil {
		b.lookedUpNames = map[string]string{}
	}
	for user, name := range names {
		b.lookedUpNames[string(roomID)+" "+string(user)] = name
	}
}

// emitHistory sends paged messages as the batch event, marked as backfill when
// they were asked for.
func emitHistory(msgs []messageObj, backfill bool) {
	const batchSize = 100
	for start := 0; start < len(msgs); start += batchSize {
		end := min(start+batchSize, len(msgs))
		frame := map[string]any{"messages": msgs[start:end]}
		if backfill {
			frame["backfill"] = true
		}
		emitEvent("messages", frame)
	}
}
