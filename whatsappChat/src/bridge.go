package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
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

	// qrCancel stops an in-flight pairing loop when a new one is requested.
	qrCancel context.CancelFunc

	stopOnce sync.Once
}

func newBridge() *bridge {
	return &bridge{
		settings:     map[string]any{},
		pendingMedia: map[string]mediaHandle{},
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
	first := b.client == nil
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
	ctx, cancel := context.WithCancel(parent)

	b.mu.Lock()
	if b.qrCancel != nil {
		b.qrCancel()
	}
	b.qrCancel = cancel
	b.mu.Unlock()

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
				// The Connected event completes the transition; nothing to do.
				return
			case "timeout":
				logf("warn", "pairing timed out, ask for a new code to retry")
				emitState("needsLogin")
				return
			default:
				logf("debug", "pairing: %s", item.Event)
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

	// Reconnect first: a client that was already connected for a previous,
	// expired pairing cannot open a second QR channel.
	client.Disconnect()
	go b.startPairing(context.Background(), client)
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
