package chat

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A provider id becomes a directory name, so anything that is not one is
// refused rather than turned into a path -- least of all one that leaves the
// store's own directory.
func TestMultiStoreRefusesWhatIsNotAProviderID(t *testing.T) {
	root := filepath.Join(t.TempDir(), "stores")
	store, err := NewMultiStore(root)
	require.NoError(t, err)
	t.Cleanup(func() { store.Close() })

	for _, id := range []string{"", ".", "..", "../escape", "a/b", `a\b`, "nul\x00byte"} {
		_, err := store.For(id)
		assert.Error(t, err, "%q should not be accepted as a provider id", id)
	}

	_, err = os.Stat(filepath.Join(filepath.Dir(root), "escape"))
	assert.True(t, os.IsNotExist(err), "nothing may be created outside the store")

	_, err = store.For("whatsappChat")
	assert.NoError(t, err)
}

// InsertMessages answers in the order it was asked, whichever provider's
// database each message went to.
func TestMultiStoreInsertMessagesKeepsOrder(t *testing.T) {
	store, err := NewMultiStore(filepath.Join(t.TempDir(), "stores"))
	require.NoError(t, err)
	t.Cleanup(func() { store.Close() })
	ctx := context.Background()

	require.NoError(t, store.PutMessage(ctx, Message{Provider: "b", ChatID: "c", ID: "seen", TS: 1, Kind: KindText}))

	fresh, err := store.InsertMessages(ctx, []Message{
		{Provider: "a", ChatID: "c", ID: "1", TS: 1, Kind: KindText},
		{Provider: "b", ChatID: "c", ID: "seen", TS: 1, Kind: KindText},
		{Provider: "a", ChatID: "c", ID: "2", TS: 2, Kind: KindText},
		{Provider: "b", ChatID: "c", ID: "new", TS: 2, Kind: KindText},
	})
	require.NoError(t, err)
	assert.Equal(t, []bool{true, false, true, true}, fresh)
}
