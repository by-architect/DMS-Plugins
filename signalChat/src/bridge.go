package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
)

type bridge struct {
	mu sync.RWMutex

	rpc *rpcClient

	// account is the phone number signal-cli registered, and the value every
	// request has to carry once more than one account could exist.
	account  string
	settings map[string]any
	mediaDir string

	// linking serialises pairing. Enabling the provider already starts a link
	// attempt; pressing Sign in would otherwise start a competing second one.
	linking sync.Mutex
	// linkStarted guards against a second automatic attempt. A plain flag under
	// mu rather than a sync.Once, because a Once that needs resetting has to be
	// reassigned, and reassigning one while another goroutine may be calling it
	// is a data race.
	linkStarted bool
	stopOnce    sync.Once
	configured  bool
}

func newBridge() *bridge {
	return &bridge{settings: map[string]any{}}
}

// beginLinking claims the right to start an automatic link attempt.
func (b *bridge) beginLinking() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.linkStarted {
		return false
	}
	b.linkStarted = true
	return true
}

// allowRelink lets the next attempt through, after one expired or failed.
func (b *bridge) allowRelink() {
	b.mu.Lock()
	b.linkStarted = false
	b.mu.Unlock()
}

func (b *bridge) getAccount() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.account
}

func (b *bridge) setAccount(account string) {
	b.mu.Lock()
	b.account = account
	b.mu.Unlock()
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
	// first should bring signal-cli up.
	if first {
		go b.connect()
	}
}

// ---------------------------------------------------------------- session

// dataDir is where signal-cli keeps its account, and with it the keys that make
// this machine a linked Signal device.
//
// Deliberately signal-cli's own default rather than somewhere under the plugin:
// the same account should be usable from the command line, and a credential
// store belongs to the tool that owns it.
func dataDir() string {
	if d := os.Getenv("SIGNAL_CLI_DATA_DIR"); d != "" {
		return d
	}
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return filepath.Join(d, "signal-cli")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "share", "signal-cli")
}

// signalCLIPath resolves the signal-cli executable.
func signalCLIPath() (string, error) {
	if p := os.Getenv("SIGNAL_CLI"); p != "" {
		return p, nil
	}
	p, err := exec.LookPath("signal-cli")
	if err != nil {
		return "", fmt.Errorf("signal-cli is not installed or not on PATH")
	}
	return p, nil
}

// connect starts signal-cli and reports where the account stands.
func (b *bridge) connect() {
	emitState("connecting")

	binary, err := signalCLIPath()
	if err != nil {
		logf("error", "%v", err)
		emitState("disconnected")
		return
	}

	client := newRPCClient()
	client.onNotify = b.onNotification
	client.onExit = func(err error) {
		// signal-cli stopping is not something this process recovers from: the
		// DMS supervisor restarts the bridge, which starts a fresh one.
		logf("warn", "signal-cli stopped: %v", err)
		emitState("disconnected")
	}

	args := []string{"--output", "json", "jsonRpc", "--receive-mode", "on-start"}
	if !b.settingBool("autoDownloadMedia", true) {
		// Told not to fetch attachments eagerly, do not let signal-cli spend the
		// bandwidth either.
		args = append(args, "--ignore-attachments")
	}
	if !b.settingBool("receiveStories", false) {
		args = append(args, "--ignore-stories")
	}

	if err := client.start(binary, args); err != nil {
		logf("error", "%v", err)
		emitState("disconnected")
		return
	}

	b.mu.Lock()
	b.rpc = client
	b.mu.Unlock()

	b.resumeOrLink()
}

// resumeOrLink connects an existing account, or asks the user to link one.
func (b *bridge) resumeOrLink() {
	accounts, err := b.listAccounts()
	if err != nil {
		logf("error", "could not list accounts: %v", err)
		emitState("disconnected")
		return
	}

	if len(accounts) == 0 {
		emitState("needsLogin")
		// Offer a code immediately. A provider that has never been linked is
		// useless until it is, so making the user press Sign in first is a step
		// with only one possible answer.
		if b.beginLinking() {
			go b.startLinking()
		}
		return
	}

	// signal-cli supports several accounts; this bridge is one provider and so
	// speaks for one of them. Preferring the configured number keeps the choice
	// with the user when they have more than one.
	chosen := accounts[0]
	if want, _ := b.settings["account"].(string); want != "" {
		for _, a := range accounts {
			if a == want {
				chosen = a
				break
			}
		}
	}

	b.setAccount(chosen)
	emitState("connected")
	logf("info", "using Signal account %s", chosen)

	go b.syncChats()
}

func (b *bridge) listAccounts() ([]string, error) {
	client := b.getRPC()
	if client == nil {
		return nil, fmt.Errorf("signal-cli is not running")
	}

	var raw []struct {
		Number string `json:"number"`
	}
	if err := client.callInto("listAccounts", map[string]any{}, &raw); err != nil {
		return nil, err
	}

	out := make([]string, 0, len(raw))
	for _, a := range raw {
		if a.Number != "" {
			out = append(out, a.Number)
		}
	}
	return out, nil
}

// startLinking drives the QR flow.
//
// signal-cli splits it in two: startLink mints a URI, finishLink blocks until
// the phone scans it. The URI is what the sign-in panel renders as a QR code.
func (b *bridge) startLinking() {
	b.linking.Lock()
	defer b.linking.Unlock()

	client := b.getRPC()
	if client == nil {
		return
	}

	var start struct {
		DeviceLinkURI string `json:"deviceLinkUri"`
	}
	if err := client.callInto("startLink", map[string]any{}, &start); err != nil {
		logf("error", "could not start linking: %v", err)
		emitState("disconnected")
		return
	}
	if start.DeviceLinkURI == "" {
		logf("error", "signal-cli returned an empty linking URI")
		emitState("disconnected")
		return
	}

	emitEvent("auth", map[string]any{"method": "qr", "qr": start.DeviceLinkURI})

	name := "DankMaterialShell"
	if n, _ := b.settings["deviceName"].(string); n != "" {
		name = n
	}

	// Blocks until the code is scanned or Signal expires it.
	var finish struct {
		Number string `json:"number"`
	}
	err := func() error {
		res, err := client.call("finishLink", map[string]any{
			"deviceLinkUri": start.DeviceLinkURI,
			"deviceName":    name,
		}, linkTimeout)
		if err != nil {
			return err
		}
		if len(res) == 0 {
			return nil
		}
		return json.Unmarshal(res, &finish)
	}()

	if err != nil {
		logf("warn", "linking did not complete: %v", err)
		// Still needsLogin rather than disconnected: the user can ask for a new
		// code, and an expired one is the ordinary outcome of walking away.
		emitState("needsLogin")
		b.allowRelink()
		return
	}

	if finish.Number != "" {
		b.setAccount(finish.Number)
	} else if accounts, err := b.listAccounts(); err == nil && len(accounts) > 0 {
		b.setAccount(accounts[0])
	}

	logf("info", "device linked")
	emitState("connected")
	go b.syncChats()
}

// ---------------------------------------------------------------- auth calls

func (b *bridge) handleLogin(ctx context.Context, c call) {
	ok(c.ID, nil)

	if b.getRPC() == nil {
		go b.connect()
		return
	}
	if b.getAccount() != "" {
		emitState("connected")
		return
	}

	// A fresh code each time Sign in is pressed; the previous one may well have
	// expired, which is usually why it was pressed.
	b.allowRelink()
	if b.beginLinking() {
		go b.startLinking()
	}
}

// handleLogout unlinks this device.
//
// signal-cli's unregister leaves the local data behind, so the account files are
// removed as well -- a user who signed out should not find themselves still
// linked the next time the bridge starts.
func (b *bridge) handleLogout(ctx context.Context, c call) {
	account := b.getAccount()
	client := b.getRPC()

	if client == nil || account == "" {
		ok(c.ID, nil)
		emitState("needsLogin")
		return
	}

	if err := client.callInto("unregister", map[string]any{"account": account}, nil); err != nil {
		// Report it and continue: the local half of signing out should still
		// happen, or the UI would claim a session that the user asked to end.
		logf("warn", "Signal did not acknowledge the unlink: %v", err)
	}

	if err := client.callInto("deleteLocalAccountData", map[string]any{
		"account":          account,
		"ignoreRegistered": true,
	}, nil); err != nil {
		logf("warn", "could not remove local account data: %v", err)
	}

	b.setAccount("")
	b.allowRelink()
	emitState("needsLogin")
	ok(c.ID, nil)
}

// handleHistory is asked to backfill older messages.
//
// Signal's servers do not keep them: a linked device receives what arrives after
// it is linked, and nothing before. Answering ok with no messages is the correct
// way to say there is nothing more, and is why the conversation view stops
// asking rather than retrying forever.
func (b *bridge) handleHistory(c call) {
	ok(c.ID, nil)
}

func (b *bridge) getRPC() *rpcClient {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.rpc == nil || !b.rpc.running() {
		return nil
	}
	return b.rpc
}

func (b *bridge) shutdown() {
	b.stopOnce.Do(func() {
		if client := b.getRPC(); client != nil {
			client.stop()
		}
		emitState("disconnected")
	})
}
