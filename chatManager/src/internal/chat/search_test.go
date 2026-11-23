package chat

import (
	"context"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFoldIgnoresCaseAccentsAndTheTurkishI(t *testing.T) {
	cases := map[string]string{
		"İstanbul":           "istanbul",
		"ISTANBUL":           "istanbul",
		"Kırmızı Çay":        "kirmizi cay",
		"ŞEKER ĞÜÖ":          "seker guo",
		"café crème":         "cafe creme",
		"Straße":             "strasse",
		"Ærø":                "aero",
		"Łódź":               "lodz",
		"İstanbul’da":        "istanbul'da",
		"“quoted”":           "\"quoted\"",
		"two\n\n  lines\t x": "two lines x",
		"café":              "cafe", // the accent written as a mark of its own
		"Ελλάδα":             "ελλαδα",
		"😂 ok":               "😂 ok",
	}
	for in, want := range cases {
		assert.Equal(t, want, string(fold(in).runes), "fold(%q)", in)
	}
}

func TestOriginalCutsWhatMatchedOutAsWritten(t *testing.T) {
	f := fold("Yarın İstanbul’da, café́!")
	at := indexRunes(f.runes, []rune("istanbul'da"))
	require.GreaterOrEqual(t, at, 0)
	assert.Equal(t, "İstanbul’da", f.original(at, at+len("istanbul'da")))

	at = indexRunes(f.runes, []rune("cafe"))
	require.GreaterOrEqual(t, at, 0)
	assert.Equal(t, "café́", f.original(at, at+4), "with the accent that follows the letter")

	g := fold("Straße")
	at = indexRunes(g.runes, []rune("strass"))
	assert.Equal(t, "Straß", g.original(at, at+6), "half of ß is all of it")
}

func TestParseSearch(t *testing.T) {
	q := parseSearch(`  Hello, "big  World" from:Ada  ?! `)
	require.Len(t, q.terms, 3)
	assert.Equal(t, "hello", string(q.terms[0].runes), "punctuation off the ends")
	assert.Equal(t, 1, q.terms[0].typos)
	assert.Equal(t, "big world", string(q.terms[1].runes))
	assert.True(t, q.terms[1].phrase)
	assert.Equal(t, "?!", string(q.terms[2].runes), "a word of punctuation alone is kept")
	assert.Equal(t, 0, q.terms[2].typos)
	assert.Equal(t, "ada", string(q.from))

	q = parseSearch(`from:"Ada Lovelace" invoice`)
	assert.Equal(t, "ada lovelace", string(q.from))
	require.Len(t, q.terms, 1)
	assert.Equal(t, "invoice", string(q.terms[0].runes))
	assert.Equal(t, 1, q.terms[0].typos)

	q = parseSearch("FROM:me")
	assert.True(t, q.fromMe)
	assert.Empty(t, q.terms)

	q = parseSearch("from:")
	require.Len(t, q.terms, 1, "from: with nothing after it is still being typed")
	assert.Equal(t, "from", string(q.terms[0].runes))

	q = parseSearch(`"unclosed phrase`)
	require.Len(t, q.terms, 1)
	assert.Equal(t, "unclosed phrase", string(q.terms[0].runes))

	assert.Equal(t, 0, parseSearch("cat").terms[0].typos, "short words are as typed")
	assert.Equal(t, 2, parseSearch("toplantıda").terms[0].typos)
	assert.Equal(t, 0, parseSearch("2024").terms[0].typos, "a number is never nearly another")
	assert.Equal(t, 0, parseSearch("c++").terms[0].typos)
	assert.True(t, parseSearch("   ").empty())
}

func TestTypoDistance(t *testing.T) {
	m := &matcher{}
	d := func(term, word string, k int) int { return m.distance([]rune(term), []rune(word), k) }
	assert.Equal(t, 0, d("mess", "message", 1), "a word starts as typed")
	assert.Equal(t, 1, d("mesage", "message", 1), "a letter missed")
	assert.Equal(t, 1, d("messsage", "message", 2), "a letter doubled")
	assert.Equal(t, 1, d("mesasge", "message", 1), "two letters swapped")
	assert.Equal(t, 1, d("mezsage", "message", 1), "a letter wrong")
	assert.Equal(t, 1, d("mesag", "message", 1), "half typed, and wrong")
	assert.Equal(t, 2, d("kitap", "kiraz", 1), "more than k is k+1")
	assert.Equal(t, 1, d("tolpantida", "toplantida", 2), "a swap is one")
	assert.Equal(t, 2, d("tplantda", "toplantida", 2), "two letters missed")
}

func TestMatch(t *testing.T) {
	m := &matcher{}
	fields := func(text string) []folded { return []folded{fold(text), fold(""), fold("")} }
	match := func(query, text string, typos bool) (bool, bool, []string) {
		return parseSearch(query).match(m, fields(text), typos)
	}

	ok, approx, marks := match("istanbul yarın", "Yarın İstanbul'a gidiyoruz", true)
	assert.True(t, ok, "words in any order, case and accents ignored")
	assert.False(t, approx)
	assert.Equal(t, []string{"İstanbul", "Yarın"}, marks)

	ok, _, marks = match("toplan", "Toplantıda görüşürüz", true)
	assert.True(t, ok, "part of a word")
	assert.Equal(t, []string{"Toplan"}, marks)

	ok, _, _ = match("cay", "Bir çay alır mısın?", true)
	assert.True(t, ok)

	ok, _, _ = match("kirmizi", "kırmızı elbise", true)
	assert.True(t, ok, "the dotless I typed as i")

	ok, approx, marks = match("mesaj gnderdim", "Mesajı gönderdim", true)
	assert.True(t, ok)
	assert.True(t, approx, "gnderdim is a letter short of gönderdim")
	assert.Equal(t, []string{"Mesaj", "gönderdim"}, marks, "a typo lights the whole word")

	ok, _, _ = match("mesaj gnderdim", "Mesajı gönderdim", false)
	assert.False(t, ok, "no typos while something matches as typed")

	ok, _, _ = match(`"big world"`, "a big world", true)
	assert.True(t, ok)
	ok, _, _ = match(`"big world"`, "world, big", true)
	assert.False(t, ok, "a phrase keeps its order")
	ok, _, _ = match(`"big wrold"`, "a big world", true)
	assert.False(t, ok, "and is never nearly matched")

	ok, approx, _ = match("ksrt", "kart", true)
	assert.True(t, ok && approx, "four letters may be one off")
	ok, _, _ = match("kst", "kat", true)
	assert.False(t, ok, "three are as typed")
	ok, _, _ = match("aprt", "kart", true)
	assert.False(t, ok, "the first letter has to be right")
	ok, _, _ = match("akrt", "kart", true)
	assert.True(t, ok, "or swapped with the second")

	ok, _, marks = parseSearch("report").match(m, []folded{fold(""), fold("Q3 Report.pdf"), fold("")}, true)
	assert.True(t, ok, "a file's name is searched")
	assert.Equal(t, []string{"Report"}, marks)
}

func TestFromAllows(t *testing.T) {
	q := parseSearch("from:ada")
	assert.True(t, q.fromAllows("Ada Lovelace", false))
	assert.False(t, q.fromAllows("Bea", false))
	assert.False(t, q.fromAllows("Ada", true), "what you sent is from:me")

	q = parseSearch("from:me")
	assert.True(t, q.fromAllows("", true))
	assert.False(t, q.fromAllows("Ada", false))

	assert.True(t, parseSearch("hello").fromAllows("anyone", false))
}

// The search bar of an open conversation, over the store.
func TestSearchChatMessagesIsClever(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	require.NoError(t, store.TouchChat(ctx, prov, "c1", "Work", "", 600, false, false))
	require.NoError(t, store.TouchChat(ctx, prov, "c2", "Home", "", 700, false, false))
	require.NoError(t, store.PutMessages(ctx, []Message{
		{Provider: prov, ID: "m1", ChatID: "c1", TS: 100, Kind: KindText, Text: "Yarın İstanbul'da toplantı var", SenderName: "Ada"},
		{Provider: prov, ID: "m2", ChatID: "c1", TS: 200, Kind: KindText, Text: "the invoice is attached", FromMe: true},
		{Provider: prov, ID: "m3", ChatID: "c1", TS: 300, Kind: KindDocument, FileName: "Invoice-March.pdf", SenderName: "Bea"},
		{Provider: prov, ID: "m4", ChatID: "c1", TS: 400, Kind: KindText, Text: "Toplantıyı erteleyelim mi?", SenderName: "Bea"},
		{Provider: prov, ID: "m5", ChatID: "c1", TS: 500, Kind: KindText, Text: "a message about something else", SenderName: "Ada"},
		{Provider: prov, ID: "m6", ChatID: "c2", TS: 600, Kind: KindText, Text: "istanbul toplantı, other conversation"},
	}))

	ids := func(hits []SearchHit) []string {
		out := []string{}
		for _, h := range hits {
			out = append(out, h.ID)
		}
		return out
	}
	search := func(query string) []SearchHit {
		hits, err := store.SearchChatMessages(ctx, prov, "c1", query, 50)
		require.NoError(t, err)
		return hits
	}

	hits := search("toplanti")
	assert.Equal(t, []string{"m4", "m1"}, ids(hits), "part of a word, Turkish letters typed plain, newest first, this conversation only")
	assert.Equal(t, []string{"Toplantı"}, hits[0].Marks)
	assert.False(t, hits[0].Approx)
	assert.Equal(t, "Work", hits[0].ChatName)

	assert.Equal(t, []string{"m1"}, ids(search("istanbul yarin")), "words in any order")
	assert.Equal(t, []string{"m3", "m2"}, ids(search("invoice")), "a document's name too")
	assert.Equal(t, []string{"m2"}, ids(search("invoice from:me")))
	assert.Equal(t, []string{"m4", "m3"}, ids(search("from:bea")))
	assert.Equal(t, []string{"m5", "m1"}, ids(search("from:ada")))

	hits = search("toplnatı")
	assert.Equal(t, []string{"m4", "m1"}, ids(hits), "nothing as typed: a typo away")
	assert.True(t, hits[0].Approx)
	assert.Equal(t, []string{"Toplantıyı"}, hits[0].Marks)

	assert.Empty(t, search("mesage someting nowhere"))
	assert.Empty(t, search(`"toplantı yarın"`), "a phrase keeps its order")
	assert.Equal(t, []string{"m1"}, ids(search(`"istanbul'da toplanti"`)))

	limited, err := store.SearchChatMessages(ctx, prov, "c1", "a", 2)
	require.NoError(t, err)
	assert.Len(t, limited, 2, "no more than asked for")
}

// A long conversation, read through on every search: what one keystroke
// costs. go test -bench SearchChat -run XXX ./internal/chat/
func BenchmarkSearchChatMessages(b *testing.B) {
	store, err := OpenHistory(b.TempDir() + "/h.db")
	require.NoError(b, err)
	defer store.Close()
	ctx := context.Background()

	words := []string{"yarın", "toplantı", "İstanbul", "çay", "message", "invoice", "tamam", "görüşürüz", "akşam", "kahve", "proje", "teslim"}
	msgs := make([]Message, 0, 20000)
	for i := 0; i < 20000; i++ {
		text := ""
		for w := 0; w < 12; w++ {
			text += words[(i*7+w*3)%len(words)] + " "
		}
		msgs = append(msgs, Message{Provider: prov, ID: "m" + strconv.Itoa(i), ChatID: "c1", TS: int64(i), Kind: KindText, Text: text})
	}
	require.NoError(b, store.PutMessages(ctx, msgs))

	for _, query := range []string{"toplanti", "zzzz nothing", "toplnati gorusuruz"} {
		b.Run(query, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				if _, err := store.SearchChatMessages(ctx, prov, "c1", query, 200); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
