package chat

import (
	"context"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Finding a message in one conversation the way people remember one: the
// words in any order, part of a word as good as the whole of it, whatever the
// case and the accents -- "istanbul" finds "İstanbul", "cay" finds "çay" --
// and a typo forgiven when nothing matches as typed.
//
// A query is words, each of which has to be somewhere in the message: its
// text, the name of a file it carries, or the title of a link in it. On top of
// that:
//
//	"two words"   a phrase: those words together, in that order, never
//	              approximately
//	from:ada      only what Ada sent (her name, or part of it); from:me only
//	              what you sent; from:"Ada Lovelace" for a name with a space
//
// Typos: a word of four letters or more may be one letter off (a letter
// missed, doubled, swapped with the next or wrong), eight or more two -- but
// only when no message has every word as typed. A word nobody misspelt is
// not buried under ones that are merely like it.
//
// SQLite's full-text index cannot do any of this: it matches whole words and
// knows nothing of Turkish, so one conversation is read through here instead.
// One conversation is small enough for that -- tens of thousands of messages
// at most, read with the index that opening it uses.

// ---------------------------------------------------------------- folding

// folded is text as a search compares it: lower case, without accents, the
// Turkish ı and İ both i, typographic quotes plain, and every run of spaces
// and line breaks a single space. at[i] is where the rune that became
// runes[i] starts in src, so what matched can be cut out of the message as it
// was written.
type folded struct {
	runes []rune
	at    []int
	src   string
}

func fold(s string) folded {
	f := folded{runes: make([]rune, 0, len(s)), at: make([]int, 0, len(s)), src: s}
	space := false
	for i, r := range s {
		if unicode.IsSpace(r) {
			if !space {
				f.runes = append(f.runes, ' ')
				f.at = append(f.at, i)
			}
			space = true
			continue
		}
		space = false
		switch {
		case r < utf8.RuneSelf:
			if 'A' <= r && r <= 'Z' {
				r += 'a' - 'A'
			}
		case unicode.Is(unicode.Mn, r):
			// An accent written as a mark of its own after its letter.
			continue
		case r == 'ß':
			f.runes = append(f.runes, 's', 's')
			f.at = append(f.at, i, i)
			continue
		case r == 'æ' || r == 'Æ':
			f.runes = append(f.runes, 'a', 'e')
			f.at = append(f.at, i, i)
			continue
		case r == 'œ' || r == 'Œ':
			f.runes = append(f.runes, 'o', 'e')
			f.at = append(f.at, i, i)
			continue
		case r == '‘' || r == '’' || r == '‛' || r == 'ʼ' || r == '´' || r == '′':
			r = '\''
		case r == '“' || r == '”' || r == '„' || r == '‟' || r == '«' || r == '»' || r == '″':
			r = '"'
		default:
			if b, ok := foldTable[r]; ok {
				r = b
			} else {
				r = unicode.ToLower(r)
			}
		}
		f.runes = append(f.runes, r)
		f.at = append(f.at, i)
	}
	return f
}

// original is runes[i:j] as the message has it: "İstanbul" where "istanbul"
// matched, with any accents written after the last letter.
func (f folded) original(i, j int) string {
	if i < 0 || j > len(f.runes) || i >= j {
		return ""
	}
	start := f.at[i]
	_, size := utf8.DecodeRuneInString(f.src[f.at[j-1]:])
	end := f.at[j-1] + size
	for end < len(f.src) {
		r, size := utf8.DecodeRuneInString(f.src[end:])
		if !unicode.Is(unicode.Mn, r) {
			break
		}
		end += size
	}
	return f.src[start:end]
}

func isWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r)
}

// ---------------------------------------------------------------- queries

type searchTerm struct {
	runes  []rune // folded
	phrase bool
	// How many letters may be wrong when nothing has the word as typed.
	typos int
}

type searchQuery struct {
	terms []searchTerm
	// from is part of the sender's name, folded; fromMe is from:me.
	from   []rune
	fromMe bool
}

func (q searchQuery) empty() bool {
	return len(q.terms) == 0 && len(q.from) == 0 && !q.fromMe
}

func isQuote(r rune) bool {
	return r == '"' || r == '“' || r == '”' || r == '„'
}

// quoted reads a quoted run starting at rs[i], the opening quote: what is
// inside, and where reading goes on. An unclosed quote runs to the end.
func quoted(rs []rune, i int) (string, int) {
	j := i + 1
	for j < len(rs) && !isQuote(rs[j]) {
		j++
	}
	return string(rs[i+1 : j]), j + 1
}

// trimPunct takes the punctuation off either end of a word -- "hello," is
// looking for hello -- unless the word is nothing else, like "?!".
func trimPunct(rs []rune) []rune {
	i, j := 0, len(rs)
	for i < j && unicode.IsPunct(rs[i]) {
		i++
	}
	for j > i && unicode.IsPunct(rs[j-1]) {
		j--
	}
	if i == j {
		return rs
	}
	return rs[i:j]
}

// typoBudget is how far off a word may be: none for short ones, where one
// letter changes the word, nor for numbers and anything with a symbol in it.
func typoBudget(rs []rune) int {
	for _, r := range rs {
		if !unicode.IsLetter(r) {
			return 0
		}
	}
	switch {
	case len(rs) >= 8:
		return 2
	case len(rs) >= 4:
		return 1
	}
	return 0
}

func parseSearch(query string) searchQuery {
	var q searchQuery
	rs := []rune(query)
	for i := 0; i < len(rs); {
		if unicode.IsSpace(rs[i]) {
			i++
			continue
		}

		if isQuote(rs[i]) {
			text, next := quoted(rs, i)
			i = next
			if phrase := []rune(strings.TrimSpace(string(fold(text).runes))); len(phrase) > 0 {
				q.terms = append(q.terms, searchTerm{runes: phrase, phrase: true})
			}
			continue
		}

		// from:name, from:"a name", from:me. "from:" with nothing after it
		// is still being typed, and searched for as a word meanwhile.
		if i+5 < len(rs) && strings.EqualFold(string(rs[i:i+5]), "from:") && !unicode.IsSpace(rs[i+5]) {
			var name string
			if isQuote(rs[i+5]) {
				name, i = quoted(rs, i+5)
			} else {
				j := i + 5
				for j < len(rs) && !unicode.IsSpace(rs[j]) {
					j++
				}
				name, i = string(rs[i+5:j]), j
			}
			who := []rune(strings.TrimSpace(string(fold(name).runes)))
			q.from, q.fromMe = nil, false
			if string(who) == "me" {
				q.fromMe = true
			} else if len(who) > 0 {
				q.from = who
			}
			continue
		}

		j := i
		for j < len(rs) && !unicode.IsSpace(rs[j]) {
			j++
		}
		word := trimPunct(fold(string(rs[i:j])).runes)
		i = j
		if len(word) > 0 {
			q.terms = append(q.terms, searchTerm{runes: word, typos: typoBudget(word)})
		}
	}
	return q
}

// ---------------------------------------------------------------- matching

func indexRunes(hay, needle []rune) int {
	n := len(needle)
	if n == 0 {
		return 0
	}
outer:
	for i := 0; i+n <= len(hay); i++ {
		if hay[i] != needle[0] {
			continue
		}
		for k := 1; k < n; k++ {
			if hay[i+k] != needle[k] {
				continue outer
			}
		}
		return i
	}
	return -1
}

func containsRunes(hay, needle []rune) bool {
	return indexRunes(hay, needle) >= 0
}

// matcher holds the rows the typo distance is worked out in, so reading a
// conversation through does not allocate three slices per word in it.
type matcher struct {
	rows [3][]int
}

// distance is how many letters the word w has to change -- one missed,
// doubled, wrong, or swapped with the next -- to start with t: the edit
// distance from t to the closest prefix of w, so a word typed only halfway,
// and wrong, is found too. Anything over k is k+1.
func (m *matcher) distance(t, w []rune, k int) int {
	cols := len(w)
	if cols > len(t)+k {
		cols = len(t) + k
	}
	for r := range m.rows {
		if cap(m.rows[r]) < cols+1 {
			m.rows[r] = make([]int, cols+1)
		}
		m.rows[r] = m.rows[r][:cols+1]
	}
	before, prev, cur := m.rows[0], m.rows[1], m.rows[2]
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(t); i++ {
		cur[0] = i
		least := i
		for j := 1; j <= cols; j++ {
			cost := 1
			if t[i-1] == w[j-1] {
				cost = 0
			}
			v := min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
			if i > 1 && j > 1 && t[i-1] == w[j-2] && t[i-2] == w[j-1] {
				v = min(v, before[j-2]+1)
			}
			cur[j] = v
			least = min(least, v)
		}
		if least > k {
			return k + 1
		}
		before, prev, cur = prev, cur, before
	}
	best := k + 1
	for j := max(0, len(t)-k); j <= cols; j++ {
		best = min(best, prev[j])
	}
	return best
}

// near finds a word in f that t is a typo of: where it is, or ok false. The
// first letter has to be right, or swapped with the second -- a typo there
// is rare, and allowing it lets nearly anything match a short word.
func (m *matcher) near(f folded, t []rune, k int) (int, int, bool) {
	n := len(f.runes)
	for i := 0; i < n; {
		if !isWordRune(f.runes[i]) {
			i++
			continue
		}
		j := i
		for j < n && isWordRune(f.runes[j]) {
			j++
		}
		w := f.runes[i:j]
		first := w[0] == t[0] || (len(w) > 1 && len(t) > 1 && w[0] == t[1] && w[1] == t[0])
		if first && len(w) >= len(t)-k && m.distance(t, w, k) <= k {
			return i, j, true
		}
		i = j
	}
	return 0, 0, false
}

// match reports whether every word of the query is in one of the fields: as
// typed, or -- when typos are allowed -- nearly. marks is what matched, one
// per word, as the message writes it: the part of the word typed when it
// matched as typed, the whole word when it was a typo, for the result to
// light up.
func (q searchQuery) match(m *matcher, fields []folded, typos bool) (ok, approx bool, marks []string) {
	marks = make([]string, 0, len(q.terms))
	for _, t := range q.terms {
		found := false
		for _, f := range fields {
			if at := indexRunes(f.runes, t.runes); at >= 0 {
				marks = append(marks, f.original(at, at+len(t.runes)))
				found = true
				break
			}
		}
		if found {
			continue
		}
		if !typos || t.phrase || t.typos == 0 {
			return false, false, nil
		}
		for _, f := range fields {
			if i, j, near := m.near(f, t.runes, t.typos); near {
				marks = append(marks, f.original(i, j))
				found = true
				break
			}
		}
		if !found {
			return false, false, nil
		}
		approx = true
	}
	return true, approx, marks
}

// fromAllows is the from: part of the query.
func (q searchQuery) fromAllows(sender string, fromMe bool) bool {
	if q.fromMe {
		return fromMe
	}
	if len(q.from) == 0 {
		return true
	}
	return !fromMe && containsRunes(fold(sender).runes, q.from)
}

// ---------------------------------------------------------------- the store

// SearchChatMessages finds messages in one conversation, newest first: the
// search bar inside an open conversation (Ctrl+Shift+F), over everything this
// device has kept of it. See the top of this file for what a query can say.
//
// Hits as typed come back when there are any; otherwise the ones a typo away,
// each with Approx set. Every hit carries Marks, what matched in it.
func (s *HistoryStore) SearchChatMessages(ctx context.Context, provider, chatID, query string, limit int) ([]SearchHit, error) {
	if chatID == "" {
		return nil, nil
	}
	q := parseSearch(query)
	if q.empty() {
		return nil, nil
	}
	if limit <= 0 {
		limit = 50
	}

	rows, err := s.db.QueryContext(ctx, `
SELECT rowid, text, file_name, link_title, sender_name, from_me
  FROM messages
 WHERE provider = ? AND chat_id = ?
 ORDER BY ts DESC`, provider, chatID)
	if err != nil {
		return nil, err
	}

	type found struct {
		rowid int64
		marks []string
	}
	var exact, approx []found
	m := &matcher{}
	for rows.Next() {
		var rowid int64
		var text, fileName, linkTitle, sender string
		var fromMe bool
		if err := rows.Scan(&rowid, &text, &fileName, &linkTitle, &sender, &fromMe); err != nil {
			rows.Close()
			return nil, err
		}
		if !q.fromAllows(sender, fromMe) {
			continue
		}
		// A typo is only looked for while nothing matches as typed: once
		// something does, the near ones are never shown.
		ok, near, marks := q.match(m, []folded{fold(text), fold(fileName), fold(linkTitle)}, len(exact) == 0)
		if !ok {
			continue
		}
		if near {
			if len(approx) < limit {
				approx = append(approx, found{rowid, marks})
			}
			continue
		}
		exact = append(exact, found{rowid, marks})
		if len(exact) >= limit {
			break
		}
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	picked, near := exact, false
	if len(picked) == 0 {
		picked, near = approx, true
	}
	if len(picked) == 0 {
		return nil, nil
	}

	ids := make([]any, len(picked))
	marksOf := make(map[int64][]string, len(picked))
	for i, f := range picked {
		ids[i] = f.rowid
		marksOf[f.rowid] = f.marks
	}
	full, err := s.db.QueryContext(ctx, `
SELECT m.rowid, `+hitColumns+`
  FROM messages m
  LEFT JOIN chats c ON c.provider = m.provider AND c.id = m.chat_id
 WHERE m.rowid IN (?`+strings.Repeat(",?", len(ids)-1)+`)
 ORDER BY m.ts DESC`, ids...)
	if err != nil {
		return nil, err
	}
	defer full.Close()

	hits, rowids, err := scanHitsWithRowID(full)
	if err != nil {
		return nil, err
	}
	for i := range hits {
		hits[i].Marks = marksOf[rowids[i]]
		hits[i].Approx = near
	}
	return hits, nil
}
