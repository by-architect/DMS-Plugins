package notify

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// A notification carries the whole message. What fits on screen is the
// notification daemon's decision, and it cannot make it about text it was
// never given.
func TestOrdinaryMessagesAreSentWhole(t *testing.T) {
	title := "DOĞA SPORLARI TOPLULUĞU VE DAĞCILIK KULÜBÜ"
	body := "Ahmet: Merhaba evet tabiki sizinle birlikte geleceğiz, saat kaçta buluşuyoruz?"

	if got := clip(title, maxSummaryRunes); got != title {
		t.Errorf("a group name was shortened:\n got %q\nwant %q", got, title)
	}
	if got := clip(body, maxBodyRunes); got != body {
		t.Errorf("a sentence was shortened:\n got %q\nwant %q", got, body)
	}
}

// The guard is there for what nobody types, and it has to cut where a character
// ends: slicing bytes puts half a Ğ on the bus.
func TestClipCutsWholeCharacters(t *testing.T) {
	long := strings.Repeat("ğü", 200)

	got := clip(long, 10)
	if !utf8.ValidString(got) {
		t.Fatalf("clip produced invalid utf-8: %q", got)
	}
	if runes := utf8.RuneCountInString(got); runes != 10 {
		t.Errorf("clip to 10 gave %d characters (%q)", runes, got)
	}
	if !strings.HasSuffix(got, "…") {
		t.Errorf("a shortened string should say so: %q", got)
	}
}

func TestClipLeavesShortStringsAlone(t *testing.T) {
	for _, value := range []string{"", "hi", "ğüş", strings.Repeat("a", 10)} {
		if got := clip(value, 10); got != value {
			t.Errorf("clip(%q) = %q, want it untouched", value, got)
		}
	}
}
