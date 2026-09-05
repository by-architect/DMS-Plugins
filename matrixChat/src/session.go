package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"maunium.net/go/mautrix/id"
)

// session is what makes this machine a logged-in Matrix device.
//
// Deliberately not in plugin_settings.json and never sent to the host: the
// access token is a bearer credential for the whole account, and the pickle key
// decrypts the end-to-end encryption store sitting next to it.
type session struct {
	HomeserverURL string `json:"homeserverUrl"`
	UserID        string `json:"userId"`
	DeviceID      string `json:"deviceId"`
	AccessToken   string `json:"accessToken"`
	// PickleKey encrypts the olm/megolm keys in crypto.db. Generated once and
	// kept for the life of the session; losing it means losing the ability to
	// read anything already encrypted to this device.
	PickleKey string `json:"pickleKey"`
}

func (s *session) valid() bool {
	return s != nil && s.HomeserverURL != "" && s.UserID != "" && s.AccessToken != ""
}

// stateDir is where the session and the encryption store live.
func stateDir() (string, error) {
	if d := os.Getenv("DMS_MATRIX_DIR"); d != "" {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return "", fmt.Errorf("create state dir: %w", err)
		}
		return d, nil
	}

	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("locate home dir: %w", err)
		}
		base = filepath.Join(home, ".local", "share")
	}

	dir := filepath.Join(base, "dms-matrix")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create state dir: %w", err)
	}
	return dir, nil
}

func sessionPath() (string, error) {
	dir, err := stateDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "session.json"), nil
}

func cryptoDBPath() (string, error) {
	dir, err := stateDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "crypto.db"), nil
}

func loadSession() (*session, error) {
	path, err := sessionPath()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// Not an error: it means nobody has signed in yet.
			return nil, nil
		}
		return nil, fmt.Errorf("read session: %w", err)
	}

	var s session
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("session file is corrupt: %w", err)
	}
	return &s, nil
}

// saveSession writes the session, readable only by its owner.
//
// Written to a temporary file and renamed, so an interrupted write cannot leave
// a half-written session that fails to parse on the next start.
func saveSession(s *session) error {
	path, err := sessionPath()
	if err != nil {
		return err
	}

	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("encode session: %w", err)
	}

	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("write session: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("install session: %w", err)
	}
	return nil
}

// clearSession removes the session and the encryption store together.
//
// Both or neither: an encryption store belonging to a device that no longer
// exists cannot decrypt anything, and keeping it only invites confusion.
func clearSession() error {
	path, err := sessionPath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}

	db, err := cryptoDBPath()
	if err != nil {
		return err
	}
	for _, p := range []string{db, db + "-wal", db + "-shm"} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

// newPickleKey mints the key that encrypts the crypto store.
func newPickleKey() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate pickle key: %w", err)
	}
	return fmt.Sprintf("%x", raw), nil
}

// ---------------------------------------------------------------- sync store

// fileSyncStore remembers the sync position between runs.
//
// Without it every start would replay the timeline from the beginning, and the
// host would re-notify for messages the user read days ago.
type fileSyncStore struct {
	mu   sync.Mutex
	path string

	FilterID  string `json:"filterId"`
	NextBatch string `json:"nextBatch"`
}

func newSyncStore() (*fileSyncStore, error) {
	dir, err := stateDir()
	if err != nil {
		return nil, err
	}

	store := &fileSyncStore{path: filepath.Join(dir, "sync.json")}
	if data, err := os.ReadFile(store.path); err == nil {
		// A corrupt file is not worth failing over: the worst case is one
		// replayed sync, which the host deduplicates anyway.
		_ = json.Unmarshal(data, store)
	}
	return store, nil
}

func (s *fileSyncStore) flush() {
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, s.path)
}

func (s *fileSyncStore) SaveFilterID(ctx context.Context, _ id.UserID, filterID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.FilterID = filterID
	s.flush()
	return nil
}

func (s *fileSyncStore) LoadFilterID(ctx context.Context, _ id.UserID) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.FilterID, nil
}

func (s *fileSyncStore) SaveNextBatch(ctx context.Context, _ id.UserID, nextBatch string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.NextBatch = nextBatch
	s.flush()
	return nil
}

func (s *fileSyncStore) LoadNextBatch(ctx context.Context, _ id.UserID) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.NextBatch, nil
}

// reset drops the sync position, used when signing out.
func (s *fileSyncStore) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.FilterID = ""
	s.NextBatch = ""
	s.flush()
}
