package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
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
		// Nothing to resume. Matrix has no scannable code to offer, so the way
		// in is the login helper; say so rather than leaving a silent panel.
		logf("info", "no Matrix session yet -- run ./login.sh in the plugin directory to sign in")
		emitState("needsLogin")
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
// Matrix has no QR flow to offer here: signing in means a password or an SSO
// round trip, and neither belongs in the shell's settings file. So this resumes
// an existing session if there is one, and otherwise points at the helper.
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

	logf("warn", "no Matrix session. Run ./login.sh in the plugin directory to sign in; "+
		"it asks for your homeserver, user id and password, exchanges them for a token, "+
		"and never stores the password.")
	emitState("needsLogin")
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
