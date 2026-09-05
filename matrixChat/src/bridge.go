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

	settings map[string]any
	mediaDir string

	syncCancel context.CancelFunc
	// firstSyncDone gates chat publishing until the initial sync has filled the
	// room cache; publishing during it would name every room after its id.
	firstSyncDone bool

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
		logf("error", "could not read the session: %v", err)
		emitState("needsLogin")
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

	store, err := newSyncStore()
	if err != nil {
		return fmt.Errorf("open sync store: %w", err)
	}
	client.Store = store

	syncer := mautrix.NewDefaultSyncer()
	client.Syncer = syncer

	b.mu.Lock()
	b.client = client
	b.sess = sess
	b.store = store
	b.mu.Unlock()

	// End-to-end encryption. Most Matrix rooms are encrypted, so without this
	// the majority of conversations would arrive as undecryptable blobs.
	if err := b.startCrypto(sess, client); err != nil {
		// Not fatal: unencrypted rooms still work, and saying so is better than
		// refusing to connect at all.
		logf("warn", "end-to-end encryption is unavailable: %v", err)
	}

	b.registerHandlers(syncer)

	ctx, cancel := context.WithCancel(context.Background())
	b.mu.Lock()
	b.syncCancel = cancel
	b.mu.Unlock()

	go b.runSync(ctx, client)
	return nil
}

// startCrypto opens the olm/megolm store.
//
// The store is SQLite through modernc's pure-Go driver, so the bridge builds
// without cgo -- the same reason the whole binary is built with the goolm tag
// rather than linking libolm.
func (b *bridge) startCrypto(sess *session, client *mautrix.Client) error {
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
		return fmt.Errorf("wrap crypto store: %w", err)
	}

	helper, err := cryptohelper.NewCryptoHelper(client, []byte(sess.PickleKey), db)
	if err != nil {
		return fmt.Errorf("build crypto helper: %w", err)
	}
	if err := helper.Init(context.Background()); err != nil {
		return fmt.Errorf("initialise encryption: %w", err)
	}

	client.Crypto = helper

	b.mu.Lock()
	b.crypto = helper
	b.db = db
	b.mu.Unlock()
	return nil
}

// runSync keeps the sync loop alive.
//
// mautrix retries transient failures itself; this only reports the state and
// backs off when the loop returns outright, which means something durable is
// wrong -- a revoked token, or a homeserver that is gone.
func (b *bridge) runSync(ctx context.Context, client *mautrix.Client) {
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
				logf("error", "the Matrix session is no longer valid: %v", err)
				_ = clearSession()
				emitState("needsLogin")
				return
			}
			logf("warn", "sync failed, retrying in %s: %v", backoff, err)
		}

		emitState("connecting")
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
		emitState("connected")
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

	b.stopSync()

	if err := clearSession(); err != nil {
		logf("warn", "could not remove the local session: %v", err)
	}

	b.mu.Lock()
	b.client = nil
	b.sess = nil
	b.crypto = nil
	b.rooms = map[id.RoomID]*roomInfo{}
	b.firstSyncDone = false
	b.mu.Unlock()

	emitState("needsLogin")
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

func (b *bridge) stopSync() {
	b.mu.Lock()
	cancel := b.syncCancel
	b.syncCancel = nil
	b.mu.Unlock()

	if cancel != nil {
		cancel()
	}
}

func (b *bridge) shutdown() {
	b.stopOnce.Do(func() {
		b.stopSync()

		b.mu.RLock()
		helper := b.crypto
		db := b.db
		b.mu.RUnlock()

		if helper != nil {
			_ = helper.Close()
		}
		if db != nil {
			_ = db.Close()
		}
		emitState("disconnected")
	})
}
