package main

import (
	"context"
	"html"
	"regexp"
	"strings"
	"unicode"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/format"
)

// Message text is Markdown in both directions. The bridge declares "markdown",
// so the host renders a message's text as Markdown -- CommonMark, ~~strike~~
// and pipe tables, every newline a line break -- and what the composer sends
// is written in it. Matrix carries formatting as HTML beside a plain body
// (org.matrix.custom.html); this file translates between the two, with
// mautrix's own renderer and converter.

// ---------------------------------------------------------------- outbound

// setText puts text from the composer into a message: the Markdown as typed is
// the body, and the HTML it renders to goes beside it when it formats anything.
// Plain text goes as plain text, which is what Element does.
func setText(content *event.MessageEventContent, text string) {
	content.Body = text
	if formatted := renderMarkdown(text); formatted != "" {
		content.Format = event.FormatHTML
		content.FormattedBody = formatted
	}
}

// renderMarkdown is the Matrix HTML that text renders to, or "" when it formats
// nothing.
//
// Markdown on and HTML off: a <tag> typed in a message is text, and is sent
// escaped. mautrix's own verdict on what is formatted is not used. It counts
// any HTML that differs from its body -- an ampersand, a quotation mark, a
// second line -- and would have sent nearly every message as HTML.
func renderMarkdown(text string) string {
	if strings.TrimSpace(text) == "" {
		return ""
	}
	rendered := format.RenderMarkdown(text, true, false)
	out := rendered.FormattedBody
	if rendered.Format != event.FormatHTML {
		// mautrix leaves the HTML out when it holds nothing but text, and
		// returns that text as the body. It can still differ from what was
		// typed: \*this\* renders as *this*.
		out = html.EscapeString(rendered.Body)
	}
	if !formats(text, out) {
		return ""
	}
	return out
}

// paragraphTags are what plain text renders to: paragraphs and line breaks.
var paragraphTags = regexp.MustCompile(`</?p>|<br ?/?>`)

// formats reports whether rendered shows anything but the text that was typed:
// a tag other than a paragraph or a line break, or text that differs -- an
// escape like \* or an entity like &copy; -- which the body would show as
// typed. Whitespace does not count; arranging lines is a paragraph's business.
func formats(typed, rendered string) bool {
	shown := html.UnescapeString(paragraphTags.ReplaceAllString(rendered, ""))
	if strings.TrimSpace(shown) == "" {
		// Nothing at all, which is what a link definition on its own renders.
		return false
	}
	return withoutSpace(shown) != withoutSpace(typed)
}

func withoutSpace(s string) string {
	return strings.Join(strings.Fields(s), "")
}

// ---------------------------------------------------------------- inbound

// markdownFromHTML is a formatted message's HTML as Markdown, or "" when the
// body has to stand in for it.
//
// The body is the fallback for HTML the converter cannot turn back into the
// same thing: a table, which it runs together into one line of cell text, and
// a list numbered from a number it cannot count from (see listsNumberSafely).
func markdownFromHTML(formatted string) string {
	if strings.TrimSpace(formatted) == "" || hasTable(formatted) || !listsNumberSafely(formatted) {
		return ""
	}
	// Whitespace is kept for markdownText, which reads it the way HTML does.
	ctx := format.NewContext(context.Background()).WithWhitespace()
	return htmlToMarkdown.Parse(formatted, ctx)
}

// htmlToMarkdown is mautrix's HTML-to-Markdown converter, set up to write the
// Markdown the host renders:
//
//   - a mention reads as the name it shows, "@Ada", rather than as a link to
//     matrix.to, a web page that only says to open a Matrix client;
//   - italics are *starred*, which also work inside a word: un*believ*able.
//     An underscore inside a word is just an underscore;
//   - underline is plain text, since Markdown has none and the host shows a
//     raw <u> as typed;
//   - text that only looks like Markdown stays text (markdownText).
var htmlToMarkdown = func() *format.HTMLParser {
	p := *format.MarkdownHTMLParser
	p.TextConverter = markdownText
	p.PillConverter = pillText
	p.BoldConverter = wrapIn("**")
	p.ItalicConverter = wrapIn("*")
	p.StrikethroughConverter = wrapIn("~~")
	p.UnderlineConverter = func(s string, _ format.Context) string { return s }
	return &p
}()

// wrapIn writes an inline style as Markdown around its text. Nothing to wrap
// is nothing at all: an empty <strong> written as **** is a horizontal rule.
func wrapIn(marker string) format.TextConverter {
	return func(s string, _ format.Context) string {
		if s == "" {
			return ""
		}
		return marker + s + marker
	}
}

// pillText writes a mention of a user as "@" and the name it showed, or the
// user id when it showed none. Rooms, aliases and links to a message keep
// mautrix's reading: the alias, or the matrix.to address, as plain text.
func pillText(displayname, mxid, eventID string, ctx format.Context) string {
	if !strings.HasPrefix(mxid, "@") {
		return format.DefaultPillConverter(displayname, mxid, eventID, ctx)
	}
	name := strings.TrimSpace(displayname)
	switch {
	case name == "":
		return mxid
	case strings.HasPrefix(name, "@"):
		return name
	}
	return "@" + name
}

// markdownText converts one run of HTML text.
//
// Code is left alone: nothing in it is read as Markdown. Elsewhere whitespace
// is read the way HTML reads it, and characters that would start formatting
// are escaped -- \*not bold\* in a message has to stay that way here, not turn
// bold on the way through.
func markdownText(s string, ctx format.Context) string {
	if ctx.TagStack.Has("pre") {
		return s
	}
	s = htmlSpace(s)
	if ctx.TagStack.Has("code") || ctx.TagStack.Has("tt") {
		return s
	}
	return escapeMarkdown(s)
}

// htmlSpace reads the whitespace in a run of text as HTML does: any run of it
// is one space. mautrix deletes newlines instead, which glued the words either
// side of one together -- every paragraph from a bot whose Markdown renderer
// keeps line breaks as newlines read "line onenext line". Newlines that open a
// run are still dropped: they are the indentation after a tag, and the newline
// written after every <br>, which would otherwise start each line with a space.
func htmlSpace(s string) string {
	s = strings.TrimLeft(s, "\n")
	var b strings.Builder
	b.Grow(len(s))
	space := false
	for _, r := range s {
		switch r {
		case ' ', '\t', '\n', '\f', '\r':
			space = true
			continue
		}
		if space {
			b.WriteByte(' ')
			space = false
		}
		b.WriteRune(r)
	}
	if space {
		b.WriteByte(' ')
	}
	return b.String()
}

// escapeMarkdown backslash-escapes what would turn literal text into
// formatting: stars, underscores, double tildes, backticks, and backslashes
// that would escape something. Only where they could: "2 * 3" and snake_case
// are left as they are, so the text still reads -- and searches -- as written.
// Text either side of the run is not known, so its ends are escaped as though
// anything could follow.
func escapeMarkdown(s string) string {
	if !strings.ContainsAny(s, "\\*_~`") {
		return s
	}
	runes := []rune(s)
	var b strings.Builder
	b.Grow(len(s) + 8)
	for i, r := range runes {
		var prev, next rune
		if i > 0 {
			prev = runes[i-1]
		}
		if i+1 < len(runes) {
			next = runes[i+1]
		}
		if needsEscape(r, prev, next) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// needsEscape decides for one character, prev and next being its neighbours,
// or 0 at either end of the run.
func needsEscape(r, prev, next rune) bool {
	switch r {
	case '`':
		return true
	case '\\':
		// Only a backslash before punctuation escapes anything.
		return next == 0 || isASCIIPunct(next)
	case '*':
		// With a space either side it can neither open nor close.
		return !(isSpace(prev) && isSpace(next))
	case '_':
		// Inside a word it cannot either.
		return !(isSpace(prev) && isSpace(next)) && !(isWordChar(prev) && isWordChar(next))
	case '~':
		// Strikethrough takes two.
		return prev == '~' || next == '~'
	}
	return false
}

func isSpace(r rune) bool { return r != 0 && unicode.IsSpace(r) }

func isWordChar(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }

// isASCIIPunct is CommonMark's ASCII punctuation: what a backslash escapes.
func isASCIIPunct(r rune) bool {
	return strings.ContainsRune("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", r)
}

// hasTable reports whether HTML holds a table. mautrix's converter has no
// table support and runs the cells together into one line, so a table sent
// from here -- a pipe table renders to one -- came back as a jumble.
func hasTable(h string) bool {
	return strings.Contains(strings.ToLower(h), "<table")
}

// A start attribute where HTML would read one -- the name in any case, an
// equals sign, then a quoted value up to its closing quote (or the end, when it
// has none) or a bare value up to whitespace or the end of the tag. Anchored,
// because it is tried at every "start" there is: searching on from a match
// instead let a decoy's quoted value swallow the real attribute after it.
var (
	startWord      = regexp.MustCompile(`(?i)start`)
	startAttribute = regexp.MustCompile(`^(?i:start)[\t\n\f\r ]*=[\t\n\f\r ]*(?:"([^"]*)|'([^']*)|([^\t\n\f\r >]*))`)
	longNumber     = regexp.MustCompile(`[0-9]{10,}`)
)

// listsNumberSafely reports whether every numbered list in HTML starts at a
// number mautrix can count from.
//
// mautrix reads <ol start> with strconv.Atoi, ignoring the range error that
// comes with a clamped value, and sizes the numbers with a Digits function
// that never returns for the smallest int64 -- reached from a start at or
// below it, or from one near the largest, where counting the items wraps
// around. The bridge dies of a stack overflow, which no recover catches. Any
// member of any room could send such a list, and the sync would hand it over
// again after every restart. So HTML naming a start of ten digits or more is
// not converted, and the host gets the body; no real list is numbered that far.
//
// Over-cautious on purpose. It looks at every "start" in the HTML -- in text,
// in comments, in other attributes -- and both as written and with entities
// decoded (&#45;9223372036854775808 is the same number to a browser), because
// missing one is fatal and a false alarm only means a plain body.
func listsNumberSafely(h string) bool {
	for _, at := range startWord.FindAllStringIndex(h, -1) {
		m := startAttribute.FindStringSubmatch(h[at[0]:])
		if m == nil {
			continue
		}
		value := m[1] + m[2] + m[3]
		if longNumber.MatchString(value) || longNumber.MatchString(html.UnescapeString(value)) {
			return false
		}
	}
	return true
}
