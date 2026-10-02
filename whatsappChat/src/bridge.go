package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"

	_ "modernc.org/sqlite"
)

// mediaCacheSize bounds how many downloadable messages are remembered for a
// later fetchMedia call.
//
// The proto is kept rather than the bytes: attachments are only downloaded when
// the user actually opens one, which is what keeps a large history sync from
// pulling gigabytes nobody asked for.
const mediaCacheSize = 4000

type bridge struct {
	mu sync.RWMutex

	client    *whatsmeow.Client
	container *sqlstore.Container

	settings map[string]any
	mediaDir string

	// pendingMedia maps a message ID to the proto needed to download it later.
	// Bounded, oldest evicted first, since this is a cache and not storage --
	// storage is the host's job.
	pendingMedia map[string]mediaHandle
	mediaOrder   []string

	// unread holds, per conversation, the incoming messages no read receipt has
	// gone out for yet. WhatsApp marks messages read by id, and the host only
	// ever says "read up to now" -- so without this list markRead had nothing
	// to send. Entries leave when they are marked read here, or when the phone
	// says it read them first.
	unread map[string][]unreadRef

	// groupNames caches each group's subject. Looking one up is a round trip to
	// WhatsApp, and every incoming group message used to make one, inside the
	// event handler -- so a reconnect replaying a few hundred group messages
	// spent minutes on names it already had.
	groupNames map[types.JID]string

	// qrCancel stops an in-flight pairing loop when a new one is requested.
	qrCancel context.CancelFunc

	// pairMu serialises pairing attempts. Separate from mu because pairing
	// waits on the network and must not hold the state lock while doing so.
	pairMu sync.Mutex

	// configured is set by the first configure call, under mu, so that only
	// that one brings the connection up. Deciding from the client being nil
	// was not enough: connect sets it only after opening the session store,
	// and a second configure landing in that gap -- a settings change, or the
	// manager re-registering this provider -- started a second client on the
	// same session, and the two took turns knocking each other offline.
	configured bool

	stopOnce sync.Once
}

// unreadRef is an incoming message that has not been marked read yet.
type unreadRef struct {
	id     types.MessageID
	sender types.JID
	ts     int64
}

// maxUnreadPerChat bounds how many unacknowledged messages are remembered for
// one conversation. Past it the oldest go without a read receipt, which only
// costs the sender a blue tick.
const maxUnreadPerChat = 200

func newBridge() *bridge {
	return &bridge{
		settings:     map[string]any{},
		pendingMedia: map[string]mediaHandle{},
		unread:       map[string][]unreadRef{},
		groupNames:   map[types.JID]string{},
	}
}

func (b *bridge) getClient() *whatsmeow.Client {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.client
}

// settingBool reads a user preference pushed down by the host at configure
// time. The bridge never reads the shell's settings files itself.
func (b *bridge) settingBool(key string, fallback bool) bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if v, ok := b.settings[key].(bool); ok {
		return v
	}
	return fallback
}

// settingInt reads a numeric preference. JSON numbers arrive as float64, so the
// obvious int assertion would always miss.
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
		go b.connect(context.Background())
	}
}

// ---------------------------------------------------------------- session

// sessionPath is where WhatsApp's own credentials live.
//
// Deliberately not in the plugin directory and never in plugin settings: this
// database is the linked device itself, and anyone holding it can read the
// account.
func sessionPath() (string, error) {
	dir := os.Getenv("XDG_DATA_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("locate home dir: %w", err)
		}
		dir = filepath.Join(home, ".local", "share")
	}

	dir = filepath.Join(dir, "dms-whatsapp")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create session dir: %w", err)
	}
	return filepath.Join(dir, "session.db"), nil
}

// connect opens the session store and brings the client online, pairing first
// if this device has never been linked.
func (b *bridge) connect(ctx context.Context) {
	emitState("connecting")

	path, err := sessionPath()
	if err != nil {
		logf("error", "%v", err)
		emitState("disconnected")
		return
	}

	// modernc's driver registers as "sqlite"; whatsmeow only needs the dialect
	// prefix to match.
	dsn := "file:" + path + "?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_txlock=immediate"

	container, err := sqlstore.New(ctx, "sqlite", dsn, waLog.Noop)
	if err != nil {
		logf("error", "could not open the session store: %v", err)
		emitState("disconnected")
		return
	}

	// SQLite creates its files 0644; these hold credentials.
	secureFiles(path)

	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		logf("error", "could not read the session store: %v", err)
		emitState("disconnected")
		return
	}

	client := whatsmeow.NewClient(device, waLog.Noop)
	client.AddEventHandler(b.handleWhatsAppEvent)

	b.mu.Lock()
	b.container = container
	b.client = client
	b.mu.Unlock()

	if client.Store.ID == nil {
		// Never linked: pairing has to happen before connecting.
		b.startPairing(ctx, client)
		return
	}

	// The shell often starts before the network does, and whatsmeow only
	// retries a connection that dropped -- not one that never came up. Without
	// this a first dial that failed at login left WhatsApp disconnected until
	// the plugin was switched off and on again. With it whatsmeow keeps trying
	// in the background, reports Disconnected meanwhile, and Connected once it
	// gets through.
	client.InitialAutoReconnect = true

	if err := client.Connect(); err != nil {
		logf("error", "could not connect: %v", err)
		emitState("disconnected")
		return
	}
}

// startPairing drives the QR flow, streaming each code to the host to render.
//
// WhatsApp rotates the code every ~20s and the channel delivers each one, so
// the panel stays scannable without the user having to ask for a new code.
func (b *bridge) startPairing(parent context.Context, client *whatsmeow.Client) {
	// Only one pairing attempt at a time. Enabling the provider already starts
	// one, and pressing Sign in would otherwise start a second that fails.
	b.pairMu.Lock()
	defer b.pairMu.Unlock()

	ctx, cancel := context.WithCancel(parent)

	b.mu.Lock()
	if b.qrCancel != nil {
		b.qrCancel()
	}
	b.qrCancel = cancel
	b.mu.Unlock()

	// whatsmeow requires the QR channel to be opened before connecting, and
	// Disconnect is not synchronous -- asking for a channel while the socket is
	// still up fails with "GetQRChannel must be called before connecting".
	if client.IsConnected() {
		client.Disconnect()
		if !waitUntilDisconnected(ctx, client, 5*time.Second) {
			logf("error", "could not start pairing: the previous session did not close")
			emitState("disconnected")
			cancel()
			return
		}
	}

	qrChan, err := client.GetQRChannel(ctx)
	if err != nil {
		logf("error", "could not start pairing: %v", err)
		emitState("disconnected")
		cancel()
		return
	}

	if err := client.Connect(); err != nil {
		logf("error", "could not connect for pairing: %v", err)
		emitState("disconnected")
		cancel()
		return
	}

	emitState("needsLogin")

	go func() {
		defer cancel()
		for item := range qrChan {
			switch item.Event {
			case "code":
				emitEvent("auth", map[string]any{"method": "qr", "qr": item.Code})
			case "success":
				logf("info", "device linked")
				// Out of needsLogin straight away, so the sign-in panel does
				// not keep showing a code that has just been scanned while
				// whatsmeow reconnects. Connected and the offline replay after
				// it complete the transition.
				emitState("connecting")
				return
			case "timeout":
				logf("warn", "pairing timed out, ask for a new code to retry")
				emitState("needsLogin")
				return
			default:
				// Whatever ends a pairing other than success or a timeout --
				// an outdated client, a phone without multi-device, a passkey
				// step this bridge cannot answer -- has to be visible, or the
				// user is left looking at a code that will never work.
				if item.Error != nil {
					logf("error", "pairing failed: %v", item.Error)
				} else {
					logf("warn", "pairing: %s", item.Event)
				}
			}
		}
	}()
}

// ---------------------------------------------------------------- auth calls

func (b *bridge) handleLogin(ctx context.Context, c call) {
	client := b.getClient()
	if client == nil {
		ok(c.ID, nil)
		go b.connect(context.Background())
		return
	}

	if client.IsLoggedIn() {
		ok(c.ID, nil)
		emitState("connected")
		return
	}

	ok(c.ID, nil)

	// A device WhatsApp has unlinked -- removed under Linked devices on the
	// phone, expired, or signed out here -- is deleted from the session store,
	// and whatsmeow refuses ever to connect it again ("invalid use of deleted
	// device"). Pairing it anyway failed on the spot and dropped the sign-in
	// panel, so the only way back was switching the plugin off and on. A new
	// device is what a first install pairs with, and is what this needs too.
	if client.Store.Deleted {
		client = b.replaceDevice()
	}

	// startPairing takes care of closing any existing socket first; doing it
	// here as well raced with the pairing already running.
	go b.startPairing(context.Background(), client)
}

// replaceDevice swaps in a client for a brand new device, in the session store
// that is already open.
func (b *bridge) replaceDevice() *whatsmeow.Client {
	b.mu.Lock()
	defer b.mu.Unlock()

	client := whatsmeow.NewClient(b.container.NewDevice(), waLog.Noop)
	client.AddEventHandler(b.handleWhatsAppEvent)
	b.client = client
	return client
}

func (b *bridge) handleLogout(ctx context.Context, c call) {
	client := b.getClient()
	if client == nil {
		ok(c.ID, nil)
		return
	}

	if err := client.Logout(ctx); err != nil {
		// Report it, but still tear down locally: a user who asked to sign out
		// should not be left looking at a session they think is gone.
		logf("warn", "logout was not acknowledged by WhatsApp: %v", err)

		// Logout changes nothing locally when its request fails, so the local
		// half is done here. Left in place, the session would come straight
		// back on the next start, and signing in again would be refused for a
		// device that still counts as linked.
		if client.Store.ID != nil {
			client.Disconnect()
			if err := client.Store.Delete(ctx); err != nil {
				logf("warn", "could not remove the local session: %v", err)
			}
		}
	}

	client.Disconnect()
	emitState("needsLogin")
	ok(c.ID, nil)
}

// handleHistory is asked to backfill older messages.
//
// whatsmeow delivers history on its own schedule via HistorySync events rather
// than on demand, so there is nothing to fetch: answering ok with no messages
// is the correct way to say "nothing more right now".
func (b *bridge) handleHistory(c call) {
	ok(c.ID, nil)
}

// waitUntilDisconnected polls until the socket is actually down, since
// Disconnect only asks.
func waitUntilDisconnected(ctx context.Context, client *whatsmeow.Client, limit time.Duration) bool {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if !client.IsConnected() {
			return true
		}
		select {
		case <-time.After(50 * time.Millisecond):
		case <-ctx.Done():
			return false
		}
	}
	return !client.IsConnected()
}

// selfJID is this account's own address, needed when quoting our own message.
func (b *bridge) selfJID() types.JID {
	client := b.getClient()
	if client == nil || client.Store == nil || client.Store.ID == nil {
		return types.EmptyJID
	}
	return *client.Store.ID
}

func (b *bridge) shutdown() {
	b.stopOnce.Do(func() {
		b.mu.Lock()
		client := b.client
		container := b.container
		cancel := b.qrCancel
		b.mu.Unlock()

		if cancel != nil {
			cancel()
		}
		if client != nil {
			client.Disconnect()
		}
		if container != nil {
			container.Close()
		}
		emitState("disconnected")
	})
}

// secureFiles tightens permissions on the session database and its sidecars.
func secureFiles(path string) {
	for _, p := range []string{path, path + "-wal", path + "-shm"} {
		_ = os.Chmod(p, 0o600)
	}
}
