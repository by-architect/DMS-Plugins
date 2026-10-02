package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"go.mau.fi/util/dbutil"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto/cryptohelper"
	"maunium.net/go/mautrix/id"

	_ "modernc.org/sqlite"
)

type bridge struct {
	mu sync.RWMutex

	client *mautrix.Client
	crypto *cryptohelper.CryptoHelper
	db     *dbutil.Database
	sess   *session
	store  *fileSyncStore

	// rooms is everything known about each room: name, members, tags. Matrix
	// spreads this across state events, so it is assembled here rather than
	// asked for one field at a time.
	rooms map[id.RoomID]*roomInfo

	roomStore *roomStore

	settings map[string]any
	mediaDir string

	syncCancel context.CancelFunc
	// syncDone closes when the sync loop has returned. Stopping waits on it, so
	// the encryption store is never closed under a response still being
	// processed: mautrix saves the position before processing, so the room keys
	// such a response carried would be lost for good.
	syncDone chan struct{}
	// firstSyncDone gates chat publishing until the initial sync has filled the
	// room cache; publishing during it would name every room after its id.
	firstSyncDone bool

	// degraded is set when the sync loop has failed and not yet recovered. It
	// is what makes the next good response report connected again, rather than
	// leaving the host showing "connecting" for the rest of the session -- and
	// treating everything that arrives as live when it is in fact a catch-up.
	degraded bool

	// history holds what an initial sync carried until the response has been
	// read through, so it reaches the host as a batch -- see onMessage.
	history []messageObj

	// downloads is the queue the background downloads work from, and
	// downloadsOnce starts their workers. See queueDownload.
	downloads     chan messageObj
	downloadsOnce sync.Once

	configured bool
	stopOnce   sync.Once
}

func newBridge() *bridge {
	return &bridge{
		settings: map[string]any{},
		rooms:    map[id.RoomID]*roomInfo{},
	}
}

func (b *bridge) getClient() *mautrix.Client {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.client
}

// settingBool reads a preference the host pushed down at configure time. The
// bridge never opens the shell's settings files itself.
func (b *bridge) settingBool(key string, fallback bool) bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if v, ok := b.settings[key].(bool); ok {
		return v
	}
	return fallback
}

func (b *bridge) settingInt(key string, fallback int) int {
	b.mu.RLock()
	defer b.mu.RUnlock()

	switch v := b.settings[key].(type) {
	case float64:
		return int(v)
	case int:
		return v
	}
	return fallback
}

// ---------------------------------------------------------------- configure

func (b *bridge) handleConfigure(ctx context.Context, c call) {
	var params struct {
		Settings map[string]any `json:"settings"`
		MediaDir string         `json:"mediaDir"`
	}
	_ = json.Unmarshal(c.Params, &params)

	b.mu.Lock()
	if params.Settings != nil {
		b.settings = params.Settings
	}
	b.mediaDir = params.MediaDir
	first := !b.configured
	b.configured = true
	b.mu.Unlock()

	ok(c.ID, nil)

	// configure arrives at startup and again on every settings change; only the
	// first should bring the connection up.
	if first {
		go b.connect()
	}
}

// ---------------------------------------------------------------- connect

// connect resumes the stored session, or reports that there is none.
func (b *bridge) connect() {
	emitState("connecting")

	sess, err := loadSession()
	if err != nil {
		// With the form, as below: needsLogin alone leaves the sign-in panel
		// with nothing to fill in, and a corrupt session file is exactly the
		// case where signing in again is the way out.
		logf("error", "could not read the session: %v", err)
		emitState("needsLogin")
		b.emitLoginForm()
		return
	}
	if !sess.valid() {
		// Nothing to resume. Matrix has no scannable code, so the sign-in panel
		// asks for credentials instead.
		emitState("needsLogin")
		b.emitLoginForm()
		return
	}

	if err := b.startClient(sess); err != nil {
		logf("error", "%v", err)
		emitState("disconnected")
		return
	}
}

// startClient builds the client, opens the crypto store and starts syncing.
func (b *bridge) startClient(sess *session) error {
	client, err := mautrix.NewClient(sess.HomeserverURL, id.UserID(sess.UserID), sess.AccessToken)
	if err != nil {
		return fmt.Errorf("build client: %w", err)
	}
	client.DeviceID = id.DeviceID(sess.DeviceID)

	store, err := newSyncStore(sess.DeviceID)
	if err != nil {
		return fmt.Errorf("open sync store: %w", err)
	}
	client.Store = store

	// Loaded before syncing starts. The homeserver only sends full room state on
	// a first sync, and this run almost certainly resumes from a stored
	// position, so without the cache every room would be named after its id.
	rooms, roomStore := loadRoomCache()

	syncer := mautrix.NewDefaultSyncer()
	// Wrapped so room publishing happens after the response is applied rather
	// than before it; the wrapper still satisfies ExtensibleSyncer, which the
	// crypto helper requires.
	client.Syncer = &publishingSyncer{DefaultSyncer: syncer, b: b}

	// Made before encryption is set up rather than just before syncing: that
	// can now wait on a homeserver that is not reachable yet, and signing out
	// or stopping has to be able to end the wait.
	ctx, cancel := context.WithCancel(context.Background())

	b.mu.Lock()
	b.client = client
	b.sess = sess
	b.store = store
	b.roomStore = roomStore
	if len(rooms) > 0 {
		b.rooms = rooms
	}
	b.syncCancel = cancel
	b.mu.Unlock()

	if len(rooms) > 0 {
		logf("debug", "loaded %d rooms from the local cache", len(rooms))
	}

	// End-to-end encryption. Most Matrix rooms are encrypted, so without this
	// the majority of conversations would arrive as undecryptable blobs.
	if err := b.startCryptoWhenReachable(ctx, sess, client); err != nil {
		if ctx.Err() != nil {
			// Signed out or stopped while waiting; there is nothing to start.
			return nil
		}
		// Not fatal: unencrypted rooms still work, and saying so is better than
		// refusing to connect at all. Sending into an encrypted room is refused
		// rather than done in plain text -- see handleSend.
		logf("warn", "end-to-end encryption is unavailable: %v", err)
	}

	b.registerHandlers(syncer)

	// Before the sync loop, not beside it: invitations already waiting and
	// rooms already read elsewhere are in no response the loop will ever see,
	// and both decide whether an arriving message is worth interrupting
	// someone for. Costs nothing on a start that has already caught up.
	b.catchUp(ctx, client)

	done := make(chan struct{})
	b.mu.Lock()
	if ctx.Err() != nil {
		// Stopped during the catch-up: dropClient has already taken the cancel
		// and is not waiting on a loop that was never started.
		b.mu.Unlock()
		return nil
	}
	b.syncDone = done
	b.mu.Unlock()

	go b.runSync(ctx, client, done)
	return nil
}

// startCryptoWhenReachable sets encryption up, waiting out a homeserver that
// cannot be reached at all.
//
// Setting up checks this device's keys with the homeserver. At boot, before the
// network is up, that failed -- and the sync that followed ran the whole session
// without encryption: every encrypted event went unhandled and was passed for
// good, since the sync position moves on regardless, and nothing could be sent
// into an encrypted room. Waiting costs nothing, as the sync could not run
// without the network either. Any other failure -- a refusal, a broken store --
// will not change by waiting, and is reported straight away.
func (b *bridge) startCryptoWhenReachable(ctx context.Context, sess *session, client *mautrix.Client) error {
	backoff := time.Second
	for {
		err := b.startCrypto(ctx, sess, client)
		if err == nil || !isUnreachable(err) {
			return err
		}
		logf("warn", "cannot reach the homeserver to set up encryption, retrying in %s: %v", backoff, err)

		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return ctx.Err()
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

// isUnreachable reports a request that never got an answer: no connection, no
// response, as opposed to a homeserver that answered no.
func isUnreachable(err error) bool {
	var httpErr mautrix.HTTPError
	return errors.As(err, &httpErr) && httpErr.Response == nil && httpErr.RespError == nil
}

// startCrypto opens the olm/megolm store.
//
// The store is SQLite through modernc's pure-Go driver, so the bridge builds
// without cgo -- the same reason the whole binary is built with the goolm tag
// rather than linking libolm.
//
// A failure is undone in full, so the next attempt starts clean: the helper
// hands the client a state store over this database and leaves it there when
// it fails, and a store over a closed database is worse than none.
func (b *bridge) startCrypto(ctx context.Context, sess *session, client *mautrix.Client) error {
	path, err := cryptoDBPath()
	if err != nil {
		return err
	}

	raw, err := sql.Open("sqlite", "file:"+path+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_txlock=immediate")
	if err != nil {
		return fmt.Errorf("open crypto store: %w", err)
	}
	// One writer: SQLite permits a single write transaction, and the crypto
	// machine writes from the sync loop and from send at the same time.
	raw.SetMaxOpenConns(1)

	db, err := dbutil.NewWithDB(raw, "sqlite3")
	if err != nil {
		_ = raw.Close()
		return fmt.Errorf("wrap crypto store: %w", err)
	}

	helper, err := cryptohelper.NewCryptoHelper(client, []byte(sess.PickleKey), db)
	if err != nil {
		_ = db.Close()
		return fmt.Errorf("build crypto helper: %w", err)
	}
	if err := helper.Init(ctx); err != nil {
		client.StateStore = nil
		_ = db.Close()
		return fmt.Errorf("initialise encryption: %w", err)
	}

	b.mu.Lock()
	if ctx.Err() != nil {
		// Signed out while this was being set up. dropClient has already been
		// through and found nothing to close, so it is closed here.
		b.mu.Unlock()
		_ = helper.Close()
		return ctx.Err()
	}
	client.Crypto = helper
	b.crypto = helper
	b.db = db
	b.mu.Unlock()
	return nil
}

// runSync keeps the sync loop alive.
//
// mautrix retries transient failures itself -- publishingSyncer.OnFailedSync is
// where those are reported. This only backs off when the loop returns outright,
// which means something durable is wrong: a revoked token, or a homeserver that
// is gone.
func (b *bridge) runSync(ctx context.Context, client *mautrix.Client, done chan struct{}) {
	defer close(done)
	backoff := time.Second

	for ctx.Err() == nil {
		err := client.SyncWithContext(ctx)
		if ctx.Err() != nil {
			return
		}

		if err != nil {
			if isAuthError(err) {
				// The token is no longer good. Retrying cannot fix it, and
				// doing so would hammer the homeserver forever.
				//
				// Ended from a goroutine of its own: ending the session waits
				// for this loop to return, which it is about to.
				logf("error", "the Matrix session is no longer valid: %v", err)
				go b.endSession()
				return
			}
			logf("warn", "sync failed, retrying in %s: %v", backoff, err)
		}

		b.markDegraded(nil)
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return
		}

		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

// markDegraded records that syncing has failed, and reports connecting the
// first time. The next good response reports connected again -- see afterSync.
func (b *bridge) markDegraded(err error) {
	b.mu.Lock()
	already := b.degraded
	b.degraded = true
	b.mu.Unlock()

	if already {
		return
	}
	if err != nil {
		logf("warn", "sync failed, mautrix is retrying: %v", err)
	}
	emitState("connecting")
}

// endSession is the homeserver saying the session is over: the token revoked
// from another client, the device removed.
//
// The client used to be left in place, so the next press of Sign in found one
// and reported connected for a session that no longer existed -- and the
// needsLogin that went out carried no form, leaving the sign-in panel empty.
func (b *bridge) endSession() {
	b.dropClient()
	if err := clearSession(); err != nil {
		logf("warn", "could not remove the local session: %v", err)
	}
	emitState("needsLogin")
	b.emitLoginForm()
}

// dropClient stops the sync and closes the encryption store, so that nothing
// is left running as a session that is over -- and so the store is closed
// before clearSession deletes it, rather than written to as a deleted file.
func (b *bridge) dropClient() {
	b.stopSync()

	b.mu.Lock()
	helper, db := b.crypto, b.db
	b.client, b.sess, b.store, b.roomStore = nil, nil, nil, nil
	b.crypto, b.db = nil, nil
	b.rooms = map[id.RoomID]*roomInfo{}
	b.firstSyncDone, b.degraded = false, false
	b.history = nil
	b.mu.Unlock()

	if helper != nil {
		_ = helper.Close()
	}
	if db != nil {
		_ = db.Close()
	}
}

func isAuthError(err error) bool {
	var httpErr mautrix.HTTPError
	if !errors.As(err, &httpErr) {
		return false
	}
	if httpErr.RespError == nil {
		return false
	}
	switch httpErr.RespError.ErrCode {
	case "M_UNKNOWN_TOKEN", "M_MISSING_TOKEN", "M_FORBIDDEN":
		return true
	}
	return false
}

// ---------------------------------------------------------------- auth calls

// handleLogin is the Sign in button.
//
// Matrix has no QR to scan, so this asks for credentials instead: the host
// renders the form, sends the answers back with authSubmit, and stores none of
// them.
func (b *bridge) handleLogin(ctx context.Context, c call) {
	ok(c.ID, nil)

	if b.getClient() != nil {
		// Already signed in, and the sync loop reports its own state. Saying
		// connected here claimed it for a session that might be failing, or
		// already over -- and told the host a catch-up had finished when it
		// may not have started.
		return
	}

	sess, err := loadSession()
	if err == nil && sess.valid() {
		go b.connect()
		return
	}

	emitState("needsLogin")
	b.emitLoginForm()
}

// emitLoginForm asks the host to collect what a Matrix login needs.
//
// The homeserver is pre-filled with the common default so most people only type
// two things. Nothing here is remembered between attempts: a failed password is
// not worth keeping, and keeping it is exactly what this design avoids.
func (b *bridge) emitLoginForm() {
	emitEvent("auth", map[string]any{
		"method": "form",
		"title":  "Sign in to your Matrix homeserver.",
		"fields": []map[string]any{
			{
				"key":      "homeserver",
				"label":    "Homeserver",
				"type":     "url",
				"value":    "https://matrix.org",
				"required": true,
			},
			{
				"key":         "user",
				"label":       "User ID",
				"type":        "text",
				"placeholder": "@you:example.org",
				"required":    true,
			},
			{
				"key":      "password",
				"label":    "Password",
				"type":     "password",
				"required": true,
			},
		},
	})
}

// handleAuthSubmit signs in with what the user typed.
//
// The credentials arrive, are exchanged for an access token, and go no further:
// only the token is written, and the password is not logged even on failure.
func (b *bridge) handleAuthSubmit(ctx context.Context, c call) {
	var params struct {
		Values map[string]string `json:"values"`
	}
	if err := json.Unmarshal(c.Params, &params); err != nil {
		fail(c.ID, "bad_params", "could not read the sign-in details")
		return
	}

	// The same call carries two different things. Signing in needs a
	// homeserver, a user and a password; verifying an already-signed-in device
	// needs only the recovery key, and can arrive long afterwards from the
	// plugin's settings page.
	if recoveryKey := strings.TrimSpace(params.Values["recoveryKey"]); recoveryKey != "" {
		raw, _ := json.Marshal(map[string]string{"recoveryKey": recoveryKey})
		b.handleVerify(ctx, call{ID: c.ID, Method: "verify", Params: raw})
		return
	}

	// Refused while a session is running. Signing in again over it cleared the
	// encryption store that session still had open and started a second sync
	// loop beside the first, both writing the same position -- which is what a
	// form submitted twice did, since the form stays up until the first sync.
	if b.getClient() != nil {
		fail(c.ID, "already_signed_in", "Matrix is already signed in on this device.")
		return
	}

	homeserver := strings.TrimSpace(params.Values["homeserver"])
	user := strings.TrimSpace(params.Values["user"])
	password := params.Values["password"]

	if homeserver == "" || user == "" || password == "" {
		fail(c.ID, "bad_params", "homeserver, user id and password are all required")
		return
	}
	if !strings.Contains(homeserver, "://") {
		// A bare hostname is what people type.
		homeserver = "https://" + homeserver
	}

	sess, err := signIn(ctx, homeserver, user, password)
	if err != nil {
		// The homeserver's own words are the useful ones -- "Invalid password"
		// rather than "login failed" -- and this message is what the user sees.
		fail(c.ID, "login_failed", "%s", loginErrorMessage(err))
		return
	}

	// A new device means new encryption keys, so any store from a previous
	// session is stale and would only produce undecryptable messages.
	_ = clearSession()
	if err := saveSession(sess); err != nil {
		fail(c.ID, "login_failed", "signed in, but could not save the session: %v", err)
		return
	}

	ok(c.ID, nil)
	logf("info", "signed in as %s", sess.UserID)

	// Off needsLogin at once, so the form goes away while the first sync --
	// which can take a while on a busy account -- is still running.
	emitState("connecting")

	if err := b.startClient(sess); err != nil {
		logf("error", "%v", err)
		emitState("disconnected")
	}
}

func (b *bridge) handleLogout(ctx context.Context, c call) {
	client := b.getClient()

	if client != nil {
		// Ask the homeserver to forget this device, so the session cannot be
		// used again even if the token file survives somewhere.
		if _, err := client.Logout(ctx); err != nil {
			logf("warn", "the homeserver did not acknowledge the logout: %v", err)
		}
	}

	// The encryption store is closed before it is deleted, not after: deleted
	// while open, it was written to as a file that no longer existed.
	b.dropClient()

	if err := clearSession(); err != nil {
		logf("warn", "could not remove the local session: %v", err)
	}

	emitState("needsLogin")
	b.emitLoginForm()
	ok(c.ID, nil)
}

// handleHistory is asked to backfill older messages.
//
// Matrix does have a real backfill API, and this is where /messages would be
// paginated into the store. It is not implemented yet: answering ok with no
// messages is the contract's way of saying there is nothing more right now,
// which stops the conversation view retrying rather than leaving it spinning.
func (b *bridge) handleHistory(c call) {
	ok(c.ID, nil)
}

// stopSync ends the sync loop and waits, briefly, for it to return.
//
// The wait is what lets the encryption store be closed straight afterwards.
// It is bounded because the host allows only a few seconds between asking a
// bridge to stop and signalling it.
func (b *bridge) stopSync() {
	b.mu.Lock()
	cancel, done := b.syncCancel, b.syncDone
	b.syncCancel, b.syncDone = nil, nil
	b.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if done != nil {
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
	}
}

func (b *bridge) shutdown() {
	b.stopOnce.Do(func() {
		b.stopSync()

		b.mu.RLock()
		helper := b.crypto
		db := b.db
		b.mu.RUnlock()

		// Written on the way out so a clean stop does not lose whatever the
		// last sync learned.
		b.persistRooms()

		if helper != nil {
			_ = helper.Close()
		}
		if db != nil {
			_ = db.Close()
		}
		emitState("disconnected")
	})
}
