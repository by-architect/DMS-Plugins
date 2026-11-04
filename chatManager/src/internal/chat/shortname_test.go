package chat

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Real names from a real account: everything that is not the name goes, and
// nothing that is.
func TestShortName(t *testing.T) {
	for in, want := range map[string]string{
		"Ada Lovelace":                       "Ada Lovelace",
		"  Ada  ":                            "Ada",
		"Hamza Ayvaz (WA)":                   "Hamza Ayvaz",
		"FEND GAYRİMENKUL (WA)":              "FEND GAYRİMENKUL",
		"Ada [Telegram]":                     "Ada",
		"Ada (@ada:example.org)":             "Ada",
		"Ada (WA) (@ada:matrix.org)":         "Ada",
		"Ada (+905551234567)":                "Ada",
		"@logbot:mjolnir.tail072d3d.ts.net":  "logbot",
		"@whatsapp_905551234567:example.net": "+905551234567",
		"@whatsapp_lid-26139372290197:mjolnir.tail072d3d.ts.net":   "WhatsApp …0197",
		"@signal_8d6f0c1e-2b5a-4c3e-9f1d-0a1b2c3d4e5f:example.net": "Signal …4e5f",
		"905551234567@s.whatsapp.net":                              "+905551234567",

		// Kept: a nickname in brackets is part of the name, and an email
		// address is the name a mail bridge has.
		"Selim (Biladerim)":       "Selim (Biladerim)",
		"merovingian@disroot.org": "merovingian@disroot.org",
		"(WA)":                    "(WA)",
		"":                        "",
	} {
		assert.Equal(t, want, ShortName(in), "ShortName(%q)", in)
	}
}

// Who in the title, what in the body -- and the body is the message alone,
// where it used to start with the sender's whole name.
func TestNotificationLayout(t *testing.T) {
	ctx := context.Background()
	store := newStore(t)

	require.NoError(t, store.TouchChat(ctx, prov, "dm", "Hamza Ayvaz (WA)", "", 1000, false, false))
	require.NoError(t, store.TouchChat(ctx, prov, "group", "İYC Mersin 2025-2026 Erkek Öğrenci Yurdu", "", 1000, true, false))

	p := NewNotifyPolicy(store, nil)
	prefs := DefaultNotifyPrefs()

	dm := p.notificationFor(ctx, Message{
		Provider: prov, ChatID: "dm", Kind: KindText, Text: "are you coming?", SenderName: "Hamza Ayvaz (WA)",
	}, "Matrix Chat", prefs)
	assert.Equal(t, "Hamza Ayvaz", dm.Summary)
	assert.Equal(t, "are you coming?", dm.Body)
	assert.Equal(t, "Matrix", dm.AppName)

	group := p.notificationFor(ctx, Message{
		Provider: prov, ChatID: "group", Kind: KindText, Text: "**dinner** at 8",
		SenderName:       "@whatsapp_lid-26139372290197:mjolnir.tail072d3d.ts.net",
		SenderAvatarPath: "/cache/avatars/x.png",
	}, "Matrix Chat", prefs)
	assert.Equal(t, "WhatsApp …0197 · İYC Mersin 2025-2026 Er…", group.Summary)
	assert.Equal(t, "dinner at 8", group.Body)
	assert.Equal(t, "/cache/avatars/x.png", group.FilePath, "the sender's picture should show")

	hidden := p.notificationFor(ctx, Message{
		Provider: prov, ChatID: "dm", Kind: KindText, Text: "secret",
	}, "", NotifyPrefs{Enabled: true})
	assert.Equal(t, "New message", hidden.Body)
	assert.Equal(t, NotifyAppName, hidden.AppName)
}
