package chat

import (
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"

	"dmschatmanager/internal/log"
)

// MigrateSharedStore splits an old single-file history into one per provider.
//
// Everything used to live in one history.db. Someone upgrading has years of
// conversations in it, and silently starting from an empty store would look
// exactly like losing them.
//
// The old file is renamed rather than deleted once the split succeeds, so a
// migration that goes wrong is recoverable by hand.
func MigrateSharedStore(ctx context.Context, sharedPath string, dst *MultiStore) (migrated int, err error) {
	if _, statErr := os.Stat(sharedPath); statErr != nil {
		return 0, nil
	}

	old, err := OpenHistory(sharedPath)
	if err != nil {
		return 0, fmt.Errorf("open the old history: %w", err)
	}
	defer old.Close()

	// Every conversation, including ones with no messages: an address book entry
	// is worth keeping too.
	//
	// The limit is stated rather than left to default, because "no limit" is
	// read as 5000 by the store -- which would have quietly dropped everything
	// past the five thousandth conversation.
	chats, err := old.AllChats(ctx, math.MaxInt32)
	if err != nil {
		return 0, fmt.Errorf("read the old conversations: %w", err)
	}

	for _, c := range chats {
		store, err := dst.For(c.Provider)
		if err != nil {
			return migrated, err
		}
		if err := store.UpsertChat(ctx, c); err != nil {
			return migrated, fmt.Errorf("copy conversation %s/%s: %w", c.Provider, c.ID, err)
		}

		// Paged rather than read whole: a long-running conversation can hold
		// more messages than is sensible to hold in memory at once.
		var before int64
		for {
			msgs, hasMore, err := old.Page(ctx, c.Provider, c.ID, before, 500)
			if err != nil {
				return migrated, fmt.Errorf("read messages of %s/%s: %w", c.Provider, c.ID, err)
			}
			if len(msgs) == 0 {
				break
			}
			if err := store.PutMessages(ctx, msgs); err != nil {
				return migrated, fmt.Errorf("copy messages of %s/%s: %w", c.Provider, c.ID, err)
			}
			if !hasMore {
				break
			}
			before = msgs[0].TS
		}
		migrated++
	}

	if err := old.Close(); err != nil {
		return migrated, fmt.Errorf("close the old history: %w", err)
	}

	// Renamed with its sidecars. SQLite looks for "<db>-wal" beside the file, so
	// moving the database alone would leave the kept copy unopenable and two
	// stray files behind that look like a live database.
	kept := filepath.Join(filepath.Dir(sharedPath), "history.db.migrated")
	if err := os.Rename(sharedPath, kept); err != nil {
		return migrated, fmt.Errorf("set the old history aside: %w", err)
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if err := os.Rename(sharedPath+suffix, kept+suffix); err != nil && !os.IsNotExist(err) {
			log.Warnf("could not move %s aside: %v", filepath.Base(sharedPath+suffix), err)
		}
	}
	return migrated, nil
}
