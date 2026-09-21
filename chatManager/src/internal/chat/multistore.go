package chat

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// A database per provider.
//
// One shared database was simpler, but it meant every provider's conversations
// sat in one file: removing a provider left its messages behind, and there was
// nothing stopping one provider's rows being read while answering another's
// query. A provider now owns its own file, so uninstalling it is deleting one
// directory.
//
// The method set matches HistoryStore exactly, so callers do not know or care
// that there is more than one database underneath. Calls that name a provider
// are routed to that provider's file; calls that do not are answered by asking
// every provider and merging.
type MultiStore struct {
	root string

	mu   sync.RWMutex
	open map[string]*HistoryStore
}

func NewMultiStore(root string) (*MultiStore, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, fmt.Errorf("create chat store directory: %w", err)
	}
	return &MultiStore{root: root, open: map[string]*HistoryStore{}}, nil
}

// Root is where each provider's directory lives.
func (m *MultiStore) Root() string { return m.root }

// PathFor is the database file backing one provider.
func (m *MultiStore) PathFor(provider string) string {
	return filepath.Join(m.root, provider, "history.db")
}

// For opens a provider's database, creating it on first use.
func (m *MultiStore) For(provider string) (*HistoryStore, error) {
	if provider == "" {
		return nil, fmt.Errorf("no provider given")
	}

	m.mu.RLock()
	s, ok := m.open[provider]
	m.mu.RUnlock()
	if ok {
		return s, nil
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	// Checked again: two goroutines can both miss the read above.
	if s, ok := m.open[provider]; ok {
		return s, nil
	}

	dir := filepath.Join(m.root, provider)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create store directory for %s: %w", provider, err)
	}

	store, err := OpenHistory(filepath.Join(dir, "history.db"))
	if err != nil {
		return nil, fmt.Errorf("open store for %s: %w", provider, err)
	}
	m.open[provider] = store
	return store, nil
}

// Providers lists every provider that has a database, whether or not it is
// currently open or even installed.
func (m *MultiStore) Providers() []string {
	seen := map[string]struct{}{}

	m.mu.RLock()
	for id := range m.open {
		seen[id] = struct{}{}
	}
	m.mu.RUnlock()

	entries, err := os.ReadDir(m.root)
	if err == nil {
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			if _, err := os.Stat(filepath.Join(m.root, e.Name(), "history.db")); err == nil {
				seen[e.Name()] = struct{}{}
			}
		}
	}

	out := make([]string, 0, len(seen))
	for id := range seen {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// eachIn runs fn against the named providers only.
//
// Restricting the query is what keeps a switched-off provider from eating slots
// out of the caller's limit: filtering the merged result afterwards would let a
// provider nobody can see push visible conversations off the end of the list.
func (m *MultiStore) eachIn(providers []string, fn func(provider string, s *HistoryStore) error) error {
	var firstErr error
	for _, provider := range providers {
		if _, err := os.Stat(m.PathFor(provider)); err != nil {
			// No database yet: a provider that has never synced anything.
			continue
		}
		store, err := m.For(provider)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if err := fn(provider, store); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// each runs fn against every provider's store.
//
// A provider whose database will not open is skipped rather than failing the
// whole query: one unreadable file should not empty the chat list.
func (m *MultiStore) each(fn func(provider string, s *HistoryStore) error) error {
	var firstErr error
	for _, provider := range m.Providers() {
		store, err := m.For(provider)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if err := fn(provider, store); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (m *MultiStore) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	var firstErr error
	for id, s := range m.open {
		if err := s.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
		delete(m.open, id)
	}
	return firstErr
}

// ---------------------------------------------------------------- routed

func (m *MultiStore) UpsertChat(ctx context.Context, c Chat) error {
	s, err := m.For(c.Provider)
	if err != nil {
		return err
	}
	return s.UpsertChat(ctx, c)
}

func (m *MultiStore) TouchChat(ctx context.Context, provider, chatID, name, lastText string, ts int64, isGroup, incrementUnread bool) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.TouchChat(ctx, provider, chatID, name, lastText, ts, isGroup, incrementUnread)
}

func (m *MultiStore) ChatsForProvider(ctx context.Context, provider string, limit int) ([]Chat, error) {
	s, err := m.For(provider)
	if err != nil {
		return nil, err
	}
	return s.ChatsForProvider(ctx, provider, limit)
}

func (m *MultiStore) ChatByID(ctx context.Context, provider, chatID string) (Chat, error) {
	s, err := m.For(provider)
	if err != nil {
		return Chat{}, err
	}
	return s.ChatByID(ctx, provider, chatID)
}

func (m *MultiStore) SetArchived(ctx context.Context, provider, chatID string, archived bool) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.SetArchived(ctx, provider, chatID, archived)
}

func (m *MultiStore) SetMuted(ctx context.Context, provider, chatID string, muted bool) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.SetMuted(ctx, provider, chatID, muted)
}

func (m *MultiStore) IsMuted(ctx context.Context, provider, chatID string) bool {
	s, err := m.For(provider)
	if err != nil {
		return false
	}
	return s.IsMuted(ctx, provider, chatID)
}

func (m *MultiStore) IsArchived(ctx context.Context, provider, chatID string) bool {
	s, err := m.For(provider)
	if err != nil {
		return false
	}
	return s.IsArchived(ctx, provider, chatID)
}

func (m *MultiStore) DeleteChatIfUnwritten(ctx context.Context, provider, chatID string) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.DeleteChatIfUnwritten(ctx, provider, chatID)
}

func (m *MultiStore) SetReadUpTo(ctx context.Context, provider, chatID string, ts int64) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.SetReadUpTo(ctx, provider, chatID, ts)
}

func (m *MultiStore) PutMessage(ctx context.Context, msg Message) error {
	s, err := m.For(msg.Provider)
	if err != nil {
		return err
	}
	return s.PutMessage(ctx, msg)
}

// PutMessages groups by provider so each batch stays one transaction in the
// database it belongs to.
func (m *MultiStore) PutMessages(ctx context.Context, msgs []Message) error {
	if len(msgs) == 0 {
		return nil
	}

	byProvider := map[string][]Message{}
	for _, msg := range msgs {
		byProvider[msg.Provider] = append(byProvider[msg.Provider], msg)
	}

	for provider, batch := range byProvider {
		s, err := m.For(provider)
		if err != nil {
			return err
		}
		if err := s.PutMessages(ctx, batch); err != nil {
			return err
		}
	}
	return nil
}

func (m *MultiStore) Page(ctx context.Context, provider, chatID string, before int64, limit int) ([]Message, bool, error) {
	s, err := m.For(provider)
	if err != nil {
		return nil, false, err
	}
	return s.Page(ctx, provider, chatID, before, limit)
}

func (m *MultiStore) MessageByID(ctx context.Context, provider, chatID, id string) (Message, error) {
	s, err := m.For(provider)
	if err != nil {
		return Message{}, err
	}
	return s.MessageByID(ctx, provider, chatID, id)
}

func (m *MultiStore) SetMessageStatus(ctx context.Context, provider, id, status string) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.SetMessageStatus(ctx, provider, id, status)
}

func (m *MultiStore) MarkDeleted(ctx context.Context, provider, chatID, id string) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.MarkDeleted(ctx, provider, chatID, id)
}

func (m *MultiStore) DeleteMessage(ctx context.Context, provider, chatID, id string) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.DeleteMessage(ctx, provider, chatID, id)
}

func (m *MultiStore) MediaRefFor(ctx context.Context, provider, chatID, id string) (string, error) {
	s, err := m.For(provider)
	if err != nil {
		return "", err
	}
	return s.MediaRefFor(ctx, provider, chatID, id)
}

func (m *MultiStore) SetMediaPath(ctx context.Context, provider, chatID, id, path string) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.SetMediaPath(ctx, provider, chatID, id, path)
}

func (m *MultiStore) GetMeta(ctx context.Context, provider, key string) (string, error) {
	s, err := m.For(provider)
	if err != nil {
		return "", err
	}
	return s.GetMeta(ctx, provider, key)
}

func (m *MultiStore) SetMeta(ctx context.Context, provider, key, value string) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.SetMeta(ctx, provider, key, value)
}

// PurgeProvider empties a provider's history and removes its database, so
// "delete all messages" leaves nothing behind on disk.
func (m *MultiStore) PurgeProvider(ctx context.Context, provider string) error {
	m.mu.Lock()
	if s, ok := m.open[provider]; ok {
		_ = s.Close()
		delete(m.open, provider)
	}
	m.mu.Unlock()

	dir := filepath.Join(m.root, provider)
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("remove store for %s: %w", provider, err)
	}
	return nil
}

// -------------------------------------------------------------- merged

// Chats merges every provider's conversation list.
//
// The limit applies to the merged result, so one very busy provider cannot
// crowd the others out: each is asked for the full limit and the newest survive
// the sort.
// ChatsIn is Chats restricted to the named providers.
func (m *MultiStore) ChatsIn(ctx context.Context, providers []string, limit int) ([]Chat, error) {
	var all []Chat
	err := m.eachIn(providers, func(_ string, s *HistoryStore) error {
		chats, err := s.Chats(ctx, limit)
		if err != nil {
			return err
		}
		all = append(all, chats...)
		return nil
	})
	return trimChats(all, limit), err
}

// AllChatsIn is AllChats restricted to the named providers.
func (m *MultiStore) AllChatsIn(ctx context.Context, providers []string, limit int) ([]Chat, error) {
	var all []Chat
	err := m.eachIn(providers, func(_ string, s *HistoryStore) error {
		chats, err := s.AllChats(ctx, limit)
		if err != nil {
			return err
		}
		all = append(all, chats...)
		return nil
	})
	return trimChats(all, limit), err
}

// SearchMessagesIn is SearchMessages restricted to the named providers.
func (m *MultiStore) SearchMessagesIn(ctx context.Context, providers []string, query string, limit int) ([]SearchHit, error) {
	var all []SearchHit
	err := m.eachIn(providers, func(_ string, s *HistoryStore) error {
		hits, err := s.SearchMessages(ctx, query, limit)
		if err != nil {
			return err
		}
		all = append(all, hits...)
		return nil
	})

	sort.SliceStable(all, func(i, j int) bool { return all[i].TS > all[j].TS })
	if limit > 0 && len(all) > limit {
		all = all[:limit]
	}
	return all, err
}

func (m *MultiStore) Chats(ctx context.Context, limit int) ([]Chat, error) {
	var all []Chat
	err := m.each(func(_ string, s *HistoryStore) error {
		chats, err := s.Chats(ctx, limit)
		if err != nil {
			return err
		}
		all = append(all, chats...)
		return nil
	})
	return trimChats(all, limit), err
}

func (m *MultiStore) AllChats(ctx context.Context, limit int) ([]Chat, error) {
	var all []Chat
	err := m.each(func(_ string, s *HistoryStore) error {
		chats, err := s.AllChats(ctx, limit)
		if err != nil {
			return err
		}
		all = append(all, chats...)
		return nil
	})
	return trimChats(all, limit), err
}

func (m *MultiStore) SearchMessages(ctx context.Context, query string, limit int) ([]SearchHit, error) {
	var all []SearchHit
	err := m.each(func(_ string, s *HistoryStore) error {
		hits, err := s.SearchMessages(ctx, query, limit)
		if err != nil {
			return err
		}
		all = append(all, hits...)
		return nil
	})

	sort.SliceStable(all, func(i, j int) bool { return all[i].TS > all[j].TS })
	if limit > 0 && len(all) > limit {
		all = all[:limit]
	}
	return all, err
}

func (m *MultiStore) SearchChats(ctx context.Context, query string, limit int) ([]Chat, error) {
	var all []Chat
	err := m.each(func(_ string, s *HistoryStore) error {
		chats, err := s.SearchChats(ctx, query, limit)
		if err != nil {
			return err
		}
		all = append(all, chats...)
		return nil
	})
	return trimChats(all, limit), err
}

func (m *MultiStore) KnownTags(ctx context.Context) ([]string, error) {
	seen := map[string]struct{}{}
	err := m.each(func(_ string, s *HistoryStore) error {
		tags, err := s.KnownTags(ctx)
		if err != nil {
			return err
		}
		for _, t := range tags {
			seen[t] = struct{}{}
		}
		return nil
	})

	out := make([]string, 0, len(seen))
	for t := range seen {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i]) < strings.ToLower(out[j]) })
	return out, err
}

func (m *MultiStore) TrimOlderThan(ctx context.Context, cutoff int64) (int64, error) {
	var total int64
	err := m.each(func(_ string, s *HistoryStore) error {
		n, err := s.TrimOlderThan(ctx, cutoff)
		total += n
		return err
	})
	return total, err
}

func (m *MultiStore) MediaPaths(ctx context.Context) ([]string, error) {
	var all []string
	err := m.each(func(_ string, s *HistoryStore) error {
		paths, err := s.MediaPaths(ctx)
		if err != nil {
			return err
		}
		all = append(all, paths...)
		return nil
	})
	return all, err
}

// trimChats sorts newest first and applies the caller's limit.
func trimChats(chats []Chat, limit int) []Chat {
	sort.SliceStable(chats, func(i, j int) bool { return chats[i].LastTS > chats[j].LastTS })
	if limit > 0 && len(chats) > limit {
		chats = chats[:limit]
	}
	return chats
}
