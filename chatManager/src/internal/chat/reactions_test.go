package chat

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// History is paged backwards, so the edit of a message arrives before the
// message itself. The original turning up afterwards must not put back the text
// that was corrected -- and it is the one copy that knows when the message was
// written, so the row moves back to there.
func TestAnOriginalArrivingAfterItsEditKeepsTheEdit(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 5000, SenderID: "ada", Kind: KindText,
		Text: "corrected", EditedTS: 5000,
	}))
	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 1000, SenderID: "ada", Kind: KindText,
		Text: "orignal typo",
	}))

	got, err := store.MessageByID(ctx, prov, "c1", "m1")
	require.NoError(t, err)
	assert.Equal(t, "corrected", got.Text, "the older copy put the corrected text back")
	assert.EqualValues(t, 5000, got.EditedTS)
	assert.EqualValues(t, 1000, got.TS, "the message should sit where it was written, not where it was edited")
}

// Newer edits win over older ones, whichever order they arrive in.
func TestEditsApplyNewestLast(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	put := func(text string, edited int64) {
		require.NoError(t, store.PutMessage(ctx, Message{
			Provider: prov, ChatID: "c1", ID: "m1", TS: 1000, SenderID: "ada", Kind: KindText,
			Text: text, EditedTS: edited,
		}))
	}
	put("first", 0)
	put("third", 3000)
	put("second", 2000)

	got, err := store.MessageByID(ctx, prov, "c1", "m1")
	require.NoError(t, err)
	assert.Equal(t, "third", got.Text)
	assert.EqualValues(t, 3000, got.EditedTS)
}

// Only a message's author can edit it, on every service there is. A copy that
// claims to be an edit from somebody else is not one, and changes nothing.
func TestAnEditFromSomebodyElseIsIgnored(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 1000, SenderID: "ada", Kind: KindText, Text: "mine",
	}))
	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 2000, SenderID: "mallory", Kind: KindText,
		Text: "forged", EditedTS: 2000,
	}))

	got, err := store.MessageByID(ctx, prov, "c1", "m1")
	require.NoError(t, err)
	assert.Equal(t, "mine", got.Text)
	assert.Zero(t, got.EditedTS)
}

func TestEditMessage(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 1000, FromMe: true, Kind: KindText,
		Text: "helo", BodyHTML: "<p>helo</p>",
	}))
	require.NoError(t, store.EditMessage(ctx, prov, "c1", "m1", "hello"))

	got, err := store.MessageByID(ctx, prov, "c1", "m1")
	require.NoError(t, err)
	assert.Equal(t, "hello", got.Text)
	assert.Empty(t, got.BodyHTML, "the old text's formatting outlived the edit")
	assert.Positive(t, got.EditedTS)

	// The original redelivered must not undo it...
	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 1000, FromMe: true, Kind: KindText, Text: "helo",
	}))
	got, err = store.MessageByID(ctx, prov, "c1", "m1")
	require.NoError(t, err)
	assert.Equal(t, "hello", got.Text)

	// ...and the service's own copy of the edit, stamped by its clock, is
	// newer than ours however far this computer's clock runs ahead.
	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 1000, FromMe: true, Kind: KindText,
		Text: "hello there", BodyHTML: "<p>hello there</p>", EditedTS: 1500,
	}))
	got, err = store.MessageByID(ctx, prov, "c1", "m1")
	require.NoError(t, err)
	assert.Equal(t, "hello there", got.Text)
	assert.Equal(t, "<p>hello there</p>", got.BodyHTML)

	assert.Error(t, store.EditMessage(ctx, prov, "c1", "nope", "x"),
		"editing a message that is not stored should say so")
}

// A page carries each message's reactions, one entry per key, with ours marked
// -- which is what decides whether pressing one adds a reaction or takes ours
// back.
func TestPageCarriesReactions(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	for i, id := range []string{"m1", "m2"} {
		require.NoError(t, store.PutMessage(ctx, Message{
			Provider: prov, ChatID: "c1", ID: id, TS: int64(1000 * (i + 1)), Kind: KindText, Text: id,
		}))
	}
	require.NoError(t, store.PutReactions(ctx, []Reaction{
		{Provider: prov, ChatID: "c1", ID: "r1", MessageID: "m1", Key: "👍", SenderName: "Ada", TS: 10},
		{Provider: prov, ChatID: "c1", ID: "r2", MessageID: "m1", Key: "👍", FromMe: true, TS: 11},
		{Provider: prov, ChatID: "c1", ID: "r3", MessageID: "m1", Key: "🎉", SenderID: "@bea", TS: 12},
		// A reaction to a message not stored yet is kept for when it is.
		{Provider: prov, ChatID: "c1", ID: "r4", MessageID: "m9", Key: "👍", TS: 13},
	}))

	page, _, err := store.Page(ctx, prov, "c1", 0, 10)
	require.NoError(t, err)
	require.Len(t, page, 2)

	m1 := page[0]
	require.Len(t, m1.Reactions, 2)
	assert.Equal(t, ReactionSummary{Key: "👍", Count: 2, Mine: true, Senders: []string{"Ada"}}, m1.Reactions[0])
	assert.Equal(t, ReactionSummary{Key: "🎉", Count: 1, Senders: []string{"@bea"}}, m1.Reactions[1],
		"a sender with no name should be shown by id")
	assert.Empty(t, page[1].Reactions)

	mine, err := store.MyReaction(ctx, prov, "c1", "m1", "👍")
	require.NoError(t, err)
	assert.Equal(t, "r2", mine)
	none, err := store.MyReaction(ctx, prov, "c1", "m1", "🎉")
	require.NoError(t, err)
	assert.Empty(t, none)
}

// The echo of our own reaction carries what the copy recorded at once did not,
// and must not make it somebody else's.
func TestReactionEchoKeepsItOurs(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	require.NoError(t, store.PutReactions(ctx, []Reaction{
		{Provider: prov, ChatID: "c1", ID: "r1", MessageID: "m1", Key: "👍", FromMe: true, TS: 10},
	}))
	require.NoError(t, store.PutReactions(ctx, []Reaction{
		{Provider: prov, ChatID: "c1", ID: "r1", MessageID: "m1", Key: "👍", SenderID: "@me", SenderName: "Me", TS: 12},
	}))

	mine, err := store.MyReaction(ctx, prov, "c1", "m1", "👍")
	require.NoError(t, err)
	assert.Equal(t, "r1", mine)
}

// A deletion names a message or a reaction without saying which. Either way the
// reactions go: the one named, or every one on a message nobody can see.
func TestDeletionTakesReactionsWithIt(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 1000, Kind: KindText, Text: "hi",
	}))
	require.NoError(t, store.PutReactions(ctx, []Reaction{
		{Provider: prov, ChatID: "c1", ID: "r1", MessageID: "m1", Key: "👍", TS: 10},
		{Provider: prov, ChatID: "c1", ID: "r2", MessageID: "m1", Key: "🎉", TS: 11},
	}))

	// A reaction taken back.
	require.NoError(t, store.MarkDeleted(ctx, prov, "c1", "r1"))
	page, _, err := store.Page(ctx, prov, "c1", 0, 10)
	require.NoError(t, err)
	require.Len(t, page, 1)
	assert.Equal(t, KindText, page[0].Kind, "taking a reaction back deleted the message")
	require.Len(t, page[0].Reactions, 1)
	assert.Equal(t, "🎉", page[0].Reactions[0].Key)

	// The message itself.
	require.NoError(t, store.MarkDeleted(ctx, prov, "c1", "m1"))
	page, _, err = store.Page(ctx, prov, "c1", 0, 10)
	require.NoError(t, err)
	assert.Empty(t, page[0].Reactions, "a deleted message kept its reactions")
}

func TestPurgeAndTrimForgetReactions(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "old", TS: 1000, Kind: KindText, Text: "old",
	}))
	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "new", TS: 9000, Kind: KindText, Text: "new",
	}))
	require.NoError(t, store.PutReactions(ctx, []Reaction{
		{Provider: prov, ChatID: "c1", ID: "r1", MessageID: "old", Key: "👍", TS: 9500},
		{Provider: prov, ChatID: "c1", ID: "r2", MessageID: "new", Key: "👍", TS: 9500},
	}))

	_, err := store.TrimOlderThan(ctx, 5000)
	require.NoError(t, err)
	var left int
	require.NoError(t, store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM reactions`).Scan(&left))
	assert.Equal(t, 1, left, "only the reaction on the trimmed message should go")

	require.NoError(t, store.PurgeProvider(ctx, prov))
	require.NoError(t, store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM reactions`).Scan(&left))
	assert.Zero(t, left)
}

// Pictures of people and conversations live in the media cache too, and the
// sweep removes unreferenced files first.
func TestAvatarsCountAsReferencedMedia(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	require.NoError(t, store.UpsertChat(ctx, Chat{Provider: prov, ID: "c1", Name: "Room", AvatarPath: "/cache/room.png", Unread: -1}))
	require.NoError(t, store.PutMessage(ctx, Message{
		Provider: prov, ChatID: "c1", ID: "m1", TS: 1000, Kind: KindImage,
		MediaPath: "/cache/photo.jpg", SenderAvatarPath: "/cache/ada.png",
	}))

	paths, err := store.MediaPaths(ctx)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"/cache/photo.jpg", "/cache/ada.png", "/cache/room.png"}, paths)
}
