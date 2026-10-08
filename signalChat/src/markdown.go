package main

import (
	"bytes"
	"errors"
	"fmt"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/parser"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// Formatting.
//
// The chat window speaks Markdown -- CommonMark plus GFM strikethrough, every
// newline a line break -- and so does its composer. Signal has no markup at all:
// a message is plain text, and its formatting travels beside it as style ranges
// ("body ranges"), each naming a stretch of the text and one of BOLD, ITALIC,
// STRIKETHROUGH, MONOSPACE or SPOILER. This file translates between the two.
//
// A range counts UTF-16 code units, not bytes and not code points. That is how
// Signal's clients index a string, and signal-cli hands the numbers through
// untouched in both directions (its `send --help` says so). An emoji is two
// units, so counting anything else shifts every style after the first one.

// The styles that have Markdown to become. SPOILER has none: the window cannot
// hide text, so a spoiler arrives as plain text.
const (
	styleBold   = "BOLD"
	styleItalic = "ITALIC"
	styleStrike = "STRIKETHROUGH"
	styleMono   = "MONOSPACE"
)

// textStyle is one style range: an item of the textStyles signal-cli reports on
// a received message, and what send takes back as "start:length:STYLE".
type textStyle struct {
	Style  string `json:"style"`
	Start  int    `json:"start"`
	Length int    `json:"length"`
}

// wireStyles writes ranges the way send's textStyle and quoteTextStyle
// parameters take them.
func wireStyles(styles []textStyle) []string {
	out := make([]string, len(styles))
	for i, s := range styles {
		out[i] = fmt.Sprintf("%d:%d:%s", s.Start, s.Length, s.Style)
	}
	return out
}

// ---------------------------------------------------------------- outgoing

// markdownParser reads the composer's Markdown: goldmark's CommonMark parsers,
// and strikethrough, the one GFM extension the chat window renders.
var markdownParser = parser.NewParser(
	parser.WithBlockParsers(parser.DefaultBlockParsers()...),
	parser.WithInlineParsers(append(parser.DefaultInlineParsers(),
		util.Prioritized(strikethroughParser{}, 500))...),
	parser.WithParagraphTransformers(parser.DefaultParagraphTransformers()...),
)

// markdownToSignal turns the composer's Markdown into what Signal sends: plain
// text, and style ranges over it.
//
// It edits the source rather than writing the parse tree back out. What is
// formatting -- the markers around emphasis, a code fence, the #s of a heading,
// the backslash of an escape -- is cut, and everything else goes out byte for
// byte: quote and list markers, blank lines, indentation, raw HTML. So a
// message with no Markdown in it is sent exactly as it was typed.
func markdownToSignal(md string) (plain string, styles []textStyle) {
	// Whatever is typed must never take the bridge down. A message this cannot
	// account for goes out as typed instead.
	defer func() {
		if recover() != nil {
			plain, styles = md, nil
		}
	}()
	plain, styles, err := parseMarkdown(md)
	// Nothing left to send -- an empty code block, say -- is not a message;
	// the text as typed is.
	if err != nil || plain == "" {
		return md, nil
	}
	return plain, styles
}

// parseMarkdown is markdownToSignal without the safety net.
func parseMarkdown(md string) (string, []textStyle, error) {
	src := []byte(md)
	c := &mdConverter{src: src, spans: map[ast.Node][2]int{}, fences: map[int]bool{}}
	if err := c.convert(markdownParser.Parse(text.NewReader(src))); err != nil {
		return "", nil, err
	}
	if len(c.edits) == 0 && len(c.styles) == 0 {
		return md, nil, nil
	}
	return c.render()
}

// mdConverter collects what markdownToSignal does to one message: stretches of
// the source to cut or replace, and styles to lay over what remains.
type mdConverter struct {
	src    []byte
	edits  []mdEdit
	styles []mdStyle

	// spans caches where each inline node sits in the source, markers and all.
	spans map[ast.Node][2]int
	// fences holds where every fenced code block opens.
	fences map[int]bool
}

type mdEdit struct {
	start, stop int
	with        string
}

type mdStyle struct {
	style       string
	start, stop int
}

// errUnreadable is a parse whose layout in the source is not what this expects.
// The message is then sent as typed.
var errUnreadable = errors.New("markdown: unexpected source layout")

func (c *mdConverter) convert(doc ast.Node) error {
	// Where every fenced code block opens, first: a line that opens one is
	// never the end of the one before.
	_ = ast.Walk(doc, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if fence, ok := n.(*ast.FencedCodeBlock); ok && entering {
			if at, found := c.fenceStart(fence); found {
				c.fences[at] = true
			}
		}
		return ast.WalkContinue, nil
	})

	return ast.Walk(doc, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		var err error
		switch n := n.(type) {
		case *ast.Heading:
			err = c.heading(n)
		case *ast.FencedCodeBlock:
			return ast.WalkSkipChildren, c.fencedCode(n)
		case *ast.CodeBlock:
			c.indentedCode(n)
			return ast.WalkSkipChildren, nil
		case *ast.Emphasis:
			style := styleItalic
			if n.Level == 2 {
				style = styleBold
			}
			err = c.delimited(n, n.Level, style)
		case *strikethrough:
			err = c.delimited(n, n.Level, styleStrike)
		case *ast.CodeSpan:
			return ast.WalkSkipChildren, c.codeSpan(n)
		case *ast.Link:
			err = c.link(n, 1, n.Destination, n.Reference)
		case *ast.Image:
			err = c.link(n, 2, n.Destination, n.Reference)
		case *ast.AutoLink:
			err = c.autoLink(n)
		case *ast.Text:
			err = c.text(n)
		}
		return ast.WalkContinue, err
	})
}

// delimited handles emphasis and strikethrough: width marker characters on
// either side of what they format.
func (c *mdConverter) delimited(n ast.Node, width int, style string) error {
	start, stop, err := c.span(n)
	if err != nil {
		return err
	}
	if stop-start < 2*width || !c.markerRun(start, width) || !c.markerRun(stop-width, width) {
		return errUnreadable
	}
	c.cut(start, start+width)
	c.cut(stop-width, stop)
	c.style(style, start+width, stop-width)
	return nil
}

func (c *mdConverter) codeSpan(n *ast.CodeSpan) error {
	start, from, to, stop, err := c.codeSpanBounds(n)
	if err != nil {
		return err
	}
	c.cut(start, from)
	c.cut(to, stop)
	c.style(styleMono, from, to)
	return nil
}

// link writes a link as its text followed by its address, "text (url)": Signal
// turns a bare address into a link of its own, and would show markup as typed.
func (c *mdConverter) link(n ast.Node, width int, dest []byte, ref *ast.ReferenceLink) error {
	start, label, stop, err := c.linkBounds(n, width, ref)
	if err != nil {
		return err
	}
	url := string(util.UnescapePunctuations(dest))
	shown := strings.TrimSpace(string(c.src[start+width : label]))
	with := ""
	switch {
	case url == "" || url == shown:
	case shown == "":
		with = url
	default:
		with = " (" + url + ")"
	}
	c.cut(start, start+width)
	c.replace(label, stop, with)
	return nil
}

// autoLink drops the angle brackets of <https://...>.
func (c *mdConverter) autoLink(n *ast.AutoLink) error {
	start, stop, err := c.span(n)
	if err != nil {
		return err
	}
	c.cut(start, start+1)
	c.cut(stop-1, stop)
	return nil
}

// text honours backslash escapes, and drops the backslash that ends a line to
// break it -- the newline already does that in a chat message.
func (c *mdConverter) text(n *ast.Text) error {
	if n.IsRaw() {
		return nil
	}
	start, stop, err := c.span(n)
	if err != nil {
		return err
	}
	for i := start; i+1 < stop; i++ {
		if c.src[i] == '\\' && util.IsPunct(c.src[i+1]) {
			c.cut(i, i+1)
			i++
		}
	}
	if n.HardLineBreak() && stop < len(c.src) && c.src[stop] == '\\' {
		c.cut(stop, stop+1)
	}
	return nil
}

// heading writes a heading as a bold line, without its #s or its underline.
func (c *mdConverter) heading(n *ast.Heading) error {
	lines := n.Lines()
	if lines.Len() == 0 {
		// "#" alone has nothing to embolden, and stays as typed.
		return nil
	}
	first, last := lines.At(0), lines.At(lines.Len()-1)

	// "## Title ##": the #s and the space after them go, and so does a closing
	// run. They are found from the title back, not from the heading's
	// position, which goldmark gets wrong after a tab ("> \t# Title").
	space := first.Start
	for space > 0 && c.src[space-1] != '\n' && util.IsSpace(c.src[space-1]) {
		space--
	}
	hashes := space
	for hashes > 0 && c.src[hashes-1] == '#' {
		hashes--
	}
	if hashes < space && space < first.Start {
		end, _ := c.lineEnd(first.Stop)
		c.cut(hashes, first.Start)
		c.cut(first.Stop, end)
		c.style(styleBold, first.Start, first.Stop)
		return nil
	}

	// The title, then a line of = or -: the underline goes, with the line
	// break before it.
	end, next := c.lineEnd(last.Start)
	if next >= len(c.src) {
		return errUnreadable
	}
	underlineEnd, _ := c.lineEnd(next)
	if !setextUnderline(c.src[next:underlineEnd]) {
		return errUnreadable
	}
	c.cut(end, underlineEnd)
	c.style(styleBold, first.Start, c.trimRight(last.Start, end))
	return nil
}

// fencedCode keeps a fenced code block's content, in monospace, and drops the
// fence lines around it.
func (c *mdConverter) fencedCode(n *ast.FencedCodeBlock) error {
	open, ok := c.fenceStart(n)
	if !ok {
		return errUnreadable
	}
	ch := c.src[open]
	width := c.run(open, ch)
	openEnd, next := c.lineEnd(open)

	lines := n.Lines()
	if lines.Len() == 0 {
		// Nothing inside: the fences are all there is.
		end := openEnd
		if closeEnd, closed := c.closingFence(open, next, ch, width); closed {
			end = closeEnd
		}
		c.cut(open, end)
		return nil
	}

	bodyStart := lines.At(0).Start
	bodyEnd, after := c.lineEnd(lines.At(lines.Len() - 1).Start)
	c.cut(open, bodyStart)
	// No closing fence is fine: the block runs to the end of the message.
	if closeEnd, closed := c.closingFence(open, after, ch, width); closed {
		c.cut(bodyEnd, closeEnd)
	}
	c.style(styleMono, bodyStart, bodyEnd)
	return nil
}

// fenceStart finds where a fenced code block's opening fence begins: the first
// run of three or more ` or ~ on its line. goldmark's position for the block
// can be off by the width of a tab in front of it; the line is right.
func (c *mdConverter) fenceStart(n *ast.FencedCodeBlock) (int, bool) {
	line := n.Pos()
	if lines := n.Lines(); lines.Len() > 0 {
		// The line break ending the fence's line, just before the code.
		line = c.lineStart(lines.At(0).Start) - 1
	}
	if line < 0 || line >= len(c.src) {
		return 0, false
	}
	start := c.lineStart(line)
	end, _ := c.lineEnd(start)
	for i := start; i < end; i++ {
		if ch := c.src[i]; ch == '`' || ch == '~' {
			run := c.run(i, ch)
			if run >= 3 {
				return i, true
			}
			i += run - 1
		}
	}
	return 0, false
}

// indentedCode sets an indented code block in monospace. It stays as typed,
// indentation and all; there is nothing to cut.
func (c *mdConverter) indentedCode(n *ast.CodeBlock) {
	lines := n.Lines()
	if lines.Len() == 0 {
		return
	}
	end, _ := c.lineEnd(lines.At(lines.Len() - 1).Start)
	c.style(styleMono, lines.At(0).Start, end)
}

// span is where an inline node sits in the source, its own markers included.
func (c *mdConverter) span(n ast.Node) (int, int, error) {
	if s, ok := c.spans[n]; ok {
		return s[0], s[1], nil
	}
	start, stop, err := c.measure(n)
	if err != nil {
		return 0, 0, err
	}
	if start < 0 || stop < start || stop > len(c.src) {
		return 0, 0, errUnreadable
	}
	c.spans[n] = [2]int{start, stop}
	return start, stop, nil
}

func (c *mdConverter) measure(n ast.Node) (int, int, error) {
	switch n := n.(type) {
	case *ast.Text:
		start, stop := n.Segment.Start, n.Segment.Stop
		// What is left over of a closing run of * or _ is filed by goldmark
		// under the run's first characters -- but those are the ones that
		// closed the emphasis just before it. The leftovers really follow
		// that emphasis, and where they are matters to whatever encloses
		// them: in "_a *b**_" the closing _ comes after the second *.
		if prev := n.PreviousSibling(); prev != nil && isDelimited(prev) {
			_, prevStop, err := c.span(prev)
			if err != nil {
				return 0, 0, err
			}
			if start < prevStop {
				return prevStop, prevStop + stop - start, nil
			}
		}
		return start, stop, nil

	case *ast.Emphasis:
		return c.around(n, n.Level)
	case *strikethrough:
		return c.around(n, n.Level)

	case *ast.CodeSpan:
		start, _, _, stop, err := c.codeSpanBounds(n)
		return start, stop, err

	case *ast.Link:
		start, _, stop, err := c.linkBounds(n, 1, n.Reference)
		return start, stop, err
	case *ast.Image:
		start, _, stop, err := c.linkBounds(n, 2, n.Reference)
		return start, stop, err

	case *ast.AutoLink:
		start := n.Pos()
		stop := start + len(n.Label(c.src)) + 2
		if start < 0 || stop > len(c.src) || c.src[start] != '<' || c.src[stop-1] != '>' {
			return 0, 0, errUnreadable
		}
		return start, stop, nil

	case *ast.RawHTML:
		if n.Segments.Len() == 0 {
			return 0, 0, errUnreadable
		}
		return n.Segments.At(0).Start, n.Segments.At(n.Segments.Len() - 1).Stop, nil
	}
	return 0, 0, errUnreadable
}

// around measures a node with width markers either side of its children.
func (c *mdConverter) around(n ast.Node, width int) (int, int, error) {
	first, last := n.FirstChild(), n.LastChild()
	if first == nil {
		return 0, 0, errUnreadable
	}
	start, _, err := c.span(first)
	if err != nil {
		return 0, 0, err
	}
	_, stop, err := c.span(last)
	if err != nil {
		return 0, 0, err
	}
	start -= width
	if start < 0 {
		return 0, 0, errUnreadable
	}
	// The closing run is right after the content -- except that goldmark lets
	// a run at the start of a quote's next line close, taking the > before it
	// for punctuation. That run follows the line break and the quote marker.
	ch := c.src[start]
	for stop < len(c.src) && c.src[stop] != ch && (util.IsSpace(c.src[stop]) || c.src[stop] == '>') {
		stop++
	}
	return start, stop + width, nil
}

func isDelimited(n ast.Node) bool {
	switch n.(type) {
	case *ast.Emphasis, *strikethrough:
		return true
	}
	return false
}

// codeSpanBounds finds a code span's opening backticks at start, its content
// [from, to), and the end of its closing backticks.
func (c *mdConverter) codeSpanBounds(n *ast.CodeSpan) (start, from, to, stop int, err error) {
	start = n.Pos()
	if start < 0 || start >= len(c.src) {
		return 0, 0, 0, 0, errUnreadable
	}
	ticks := c.run(start, '`')
	if ticks == 0 {
		return 0, 0, 0, 0, errUnreadable
	}
	from, to = start+ticks, start+ticks
	if first, ok := n.FirstChild().(*ast.Text); ok {
		from = first.Segment.Start
	}
	if last, ok := n.LastChild().(*ast.Text); ok {
		to = last.Segment.Stop
	}
	// CommonMark strips a space from each end of the content when both have
	// one, and goldmark leaves it out of the content: it goes with the
	// backticks. So, across a line break, does what starts the next line of a
	// quote or a list.
	closing := to
	for closing < len(c.src) && c.src[closing] != '`' {
		if !util.IsSpace(c.src[closing]) && c.src[closing] != '>' {
			return 0, 0, 0, 0, errUnreadable
		}
		closing++
	}
	if from < start+ticks || to < from || c.run(closing, '`') != ticks {
		return 0, 0, 0, 0, errUnreadable
	}
	return start, from, to, closing + ticks, nil
}

// linkBounds finds a link's "[" (or "![") at start, its "]" at label, and the
// end of what follows: "(url "title")" for an inline link, "[ref]" or "[]" for
// a reference. goldmark keeps the start and no more, so the rest is scanned
// again; it has been accepted as a link already, so only its end is wanted.
func (c *mdConverter) linkBounds(n ast.Node, width int, ref *ast.ReferenceLink) (start, label, stop int, err error) {
	start = n.Pos()
	if start < 0 || start+width > len(c.src) || c.src[start+width-1] != '[' ||
		(width == 2 && c.src[start] != '!') {
		return 0, 0, 0, errUnreadable
	}
	label = start + width
	if last := n.LastChild(); last != nil {
		if _, label, err = c.span(last); err != nil {
			return 0, 0, 0, err
		}
	}
	// Unlike emphasis, a label can end with a line break before its "]".
	for label < len(c.src) && c.src[label] != ']' && (util.IsSpace(c.src[label]) || c.src[label] == '>') {
		label++
	}
	if label >= len(c.src) || c.src[label] != ']' {
		return 0, 0, 0, errUnreadable
	}

	ok := false
	switch {
	case ref == nil:
		stop, ok = inlineLinkEnd(c.src, label+1)
	case ref.Type == ast.ReferenceLinkShortcut:
		stop, ok = label+1, true
	default:
		stop, ok = referenceEnd(c.src, label+1)
	}
	if !ok {
		return 0, 0, 0, errUnreadable
	}
	return start, label, stop, nil
}

// inlineLinkEnd finds the end of an inline link's `(destination "title")`. The
// rules are goldmark's own, so that it ends where goldmark's link did.
func inlineLinkEnd(src []byte, i int) (int, bool) {
	if i >= len(src) || src[i] != '(' {
		return 0, false
	}
	i = skipLinkSpace(src, i+1)

	if i < len(src) && src[i] == '<' {
		for i++; i < len(src) && src[i] != '>'; i++ {
			if escaped(src, i) {
				i++
			}
		}
		i++
	} else {
		depth := 0
	destination:
		for ; i < len(src); i++ {
			switch ch := src[i]; {
			case escaped(src, i):
				i++
			case ch == '(':
				depth++
			case ch == ')':
				if depth == 0 {
					break destination
				}
				depth--
			case util.IsSpace(ch):
				break destination
			}
		}
	}

	i = skipLinkSpace(src, i)
	if i < len(src) && (src[i] == '"' || src[i] == '\'' || src[i] == '(') {
		closer := src[i]
		if closer == '(' {
			closer = ')'
		}
		for i++; i < len(src) && src[i] != closer; i++ {
			if escaped(src, i) {
				i++
			}
		}
		i = skipLinkSpace(src, i+1)
	}
	if i >= len(src) || src[i] != ')' {
		return 0, false
	}
	return i + 1, true
}

// referenceEnd finds the end of a reference link's "[ref]" or "[]".
func referenceEnd(src []byte, i int) (int, bool) {
	if i >= len(src) || src[i] != '[' {
		return 0, false
	}
	for i++; i < len(src); i++ {
		switch {
		case escaped(src, i):
			i++
		case src[i] == ']':
			return i + 1, true
		}
	}
	return 0, false
}

// skipLinkSpace skips the space inside a link's tail. Across a line break that
// includes the quote markers starting the next line, which goldmark never sees:
// it reads a paragraph's lines without them.
func skipLinkSpace(src []byte, i int) int {
	newLine := false
	for ; i < len(src); i++ {
		switch {
		case src[i] == '\n':
			newLine = true
		case util.IsSpace(src[i]):
		case src[i] == '>' && newLine:
		default:
			return i
		}
	}
	return i
}

// escaped reports whether src[i] is a backslash escaping the character after it.
func escaped(src []byte, i int) bool {
	return src[i] == '\\' && i+1 < len(src) && util.IsPunct(src[i+1])
}

// closingFence looks for the fence that closes the code block opened at open,
// on the line starting at lineStart, and returns where that line's content ends.
func (c *mdConverter) closingFence(open, lineStart int, ch byte, width int) (int, bool) {
	if lineStart >= len(c.src) {
		return 0, false
	}
	end, _ := c.lineEnd(lineStart)
	i := lineStart
	for i < end && (c.src[i] == ' ' || c.src[i] == '\t' || c.src[i] == '>') {
		i++
	}
	// A fence that opens another block is not this one's end, and nor is one
	// at a different depth of quoting: the block ended with its quote.
	if c.fences[i] || quoteDepth(c.src[lineStart:i]) != quoteDepth(c.src[c.lineStart(open):open]) {
		return 0, false
	}
	n := c.run(i, ch)
	if n < width || !blank(c.src[i+n:end]) {
		return 0, false
	}
	return end, true
}

func quoteDepth(prefix []byte) int {
	return bytes.Count(prefix, []byte{'>'})
}

// setextUnderline reports whether a line, past any quote markers, is a row of
// = or - under a heading.
func setextUnderline(line []byte) bool {
	line = bytes.TrimLeft(line, " \t>")
	if len(line) == 0 || (line[0] != '=' && line[0] != '-') {
		return false
	}
	return blank(bytes.TrimLeft(line, string(line[0])))
}

// blank reports whether b is all whitespace, as goldmark counts it.
func blank(b []byte) bool {
	for _, ch := range b {
		if !util.IsSpace(ch) {
			return false
		}
	}
	return true
}

// lineEnd returns where the line holding i ends, before its line break, and
// where the next line starts.
func (c *mdConverter) lineEnd(i int) (end, next int) {
	nl := bytes.IndexByte(c.src[i:], '\n')
	if nl < 0 {
		return len(c.src), len(c.src)
	}
	end, next = i+nl, i+nl+1
	if end > i && c.src[end-1] == '\r' {
		end--
	}
	return end, next
}

// lineStart returns where the line holding i begins.
func (c *mdConverter) lineStart(i int) int {
	return bytes.LastIndexByte(c.src[:i], '\n') + 1
}

// trimRight moves end back over spaces and tabs, but not past start.
func (c *mdConverter) trimRight(start, end int) int {
	for end > start && (c.src[end-1] == ' ' || c.src[end-1] == '\t') {
		end--
	}
	return end
}

// run counts how many times ch repeats from at.
func (c *mdConverter) run(at int, ch byte) int {
	n := 0
	for at+n < len(c.src) && c.src[at+n] == ch {
		n++
	}
	return n
}

// markerRun reports whether width bytes from at are one emphasis or
// strikethrough character, repeated.
func (c *mdConverter) markerRun(at, width int) bool {
	if at < 0 || width <= 0 || at+width > len(c.src) {
		return false
	}
	ch := c.src[at]
	return (ch == '*' || ch == '_' || ch == '~') && c.run(at, ch) >= width
}

func (c *mdConverter) cut(start, stop int) {
	c.replace(start, stop, "")
}

func (c *mdConverter) replace(start, stop int, with string) {
	if start < stop || with != "" {
		c.edits = append(c.edits, mdEdit{start, stop, with})
	}
}

func (c *mdConverter) style(style string, start, stop int) {
	if start < stop {
		c.styles = append(c.styles, mdStyle{style, start, stop})
	}
}

// render applies the edits, and moves each style from the source onto the
// result, counted in UTF-16.
func (c *mdConverter) render() (string, []textStyle, error) {
	sort.Slice(c.edits, func(i, j int) bool { return c.edits[i].start < c.edits[j].start })

	out := make([]byte, 0, len(c.src))
	// at is where each source position lands in the result. A position
	// inside a cut lands where the cut was.
	at := make([]int, len(c.src)+1)
	p := 0
	for _, e := range c.edits {
		// Edits come from separate pieces of markup and must not overlap; if
		// two do, the parse was not understood.
		if e.start < p || e.stop < e.start || e.stop > len(c.src) {
			return "", nil, errUnreadable
		}
		for ; p < e.start; p++ {
			at[p] = len(out)
			out = append(out, c.src[p])
		}
		for ; p < e.stop; p++ {
			at[p] = len(out)
		}
		out = append(out, e.with...)
	}
	for ; p < len(c.src); p++ {
		at[p] = len(out)
		out = append(out, c.src[p])
	}
	at[len(c.src)] = len(out)

	units := utf16Offsets(out)
	ranges := make([]textStyle, 0, len(c.styles))
	for _, s := range c.styles {
		if s.start < 0 || s.stop > len(c.src) {
			return "", nil, errUnreadable
		}
		from, to := at[s.start], at[s.stop]
		if from < to {
			ranges = append(ranges, textStyle{s.style, units[from], units[to] - units[from]})
		}
	}
	return string(out), normalizeStyles(ranges), nil
}

// strikethrough is GFM's ~~text~~, which also takes a single ~. goldmark has an
// extension for it, but that forgets how many tildes each one used; this keeps
// the count, which is how many characters to cut. And as in GFM itself, the
// two runs must be the same length: "~~a~" is no strikethrough.
type strikethrough struct {
	ast.BaseInline
	Level int
}

var kindStrikethrough = ast.NewNodeKind("SignalStrikethrough")

func (n *strikethrough) Kind() ast.NodeKind { return kindStrikethrough }

func (n *strikethrough) Dump(source []byte, level int) {
	ast.DumpHelper(n, source, level, map[string]string{"Level": fmt.Sprint(n.Level)}, nil)
}

type strikethroughParser struct{}

func (strikethroughParser) Trigger() []byte { return []byte{'~'} }

func (strikethroughParser) Parse(parent ast.Node, block text.Reader, pc parser.Context) ast.Node {
	before := block.PrecendingCharacter()
	line, segment := block.PeekLine()
	d := parser.ScanDelimiter(line, before, 1, strikethroughDelimiter{})
	if d == nil || d.OriginalLength > 2 || before == '~' {
		return nil
	}
	d.Segment = segment.WithStop(segment.Start + d.OriginalLength)
	block.Advance(d.OriginalLength)
	pc.PushDelimiter(d)
	return d
}

type strikethroughDelimiter struct{}

func (strikethroughDelimiter) IsDelimiter(b byte) bool { return b == '~' }

func (strikethroughDelimiter) CanOpenCloser(opener, closer *parser.Delimiter) bool {
	return opener.Char == closer.Char && opener.OriginalLength == closer.OriginalLength
}

func (strikethroughDelimiter) OnMatch(consumes int) ast.Node {
	return &strikethrough{Level: consumes}
}

// ---------------------------------------------------------------- incoming

// signalToMarkdown writes a received message as Markdown: its text, with its
// style ranges turned into markers.
//
// Markers are all that is added. The text itself is never escaped, so a
// message without formatting arrives byte for byte as it was sent -- and one
// whose sender typed *this* by hand shows italics, as they most likely meant.
func signalToMarkdown(msg string, styles []textStyle) (md string) {
	// A malformed message must not take the bridge down either. It is passed
	// on as the plain text it is.
	defer func() {
		if recover() != nil {
			md = msg
		}
	}()
	return formatMarks(msg, styleMarks(msg, styles))
}

// formatMarks is signalToMarkdown without the safety net.
func formatMarks(msg string, marks []mdMark) (md string) {
	if len(marks) == 0 {
		return msg
	}

	// A text with no Markdown of its own can be checked: read back, the result
	// has to give the same text and the same styles. When it does not, a
	// marker landed where CommonMark takes none -- inside a word, against
	// punctuation -- and something simpler is tried. A text that does have
	// Markdown of its own reads back as more than its styles, so it cannot be
	// checked this way; it gets the plain rendering.
	if plain, own, err := parseMarkdown(msg); err != nil || plain != msg || len(own) > 0 {
		md, _, _ = renderMarks(msg, marks, "*")
		return md
	}
	if md, ok := checkedMarkdown(msg, marks); ok {
		return md
	}

	// Some range cannot be written as it is. Keep every one that can, rather
	// than losing them all for the sake of one -- if need be without the
	// punctuation at its ends: in "x(note)y" CommonMark takes no marker
	// between x and the bracket, but "x(**note**)y" is fine. The same rule
	// is what stops bold on 「quoted」 Japanese between two letters.
	md = msg
	var kept []mdMark
	for _, m := range marks {
		for _, try := range []mdMark{m, trimPunct(msg, m)} {
			if out, ok := checkedMarkdown(msg, append(kept[:len(kept):len(kept)], try)); ok {
				kept, md = append(kept, try), out
				break
			}
		}
	}
	return md
}

// trimPunct narrows a mark past punctuation and space at either end. Code is
// left alone: its punctuation is part of it.
func trimPunct(msg string, m mdMark) mdMark {
	if m.style == styleMono {
		return m
	}
	edge := func(r rune) bool { return util.IsPunctRune(r) || util.IsSpaceRune(r) }
	from, to := m.start, m.stop
	for from < to {
		r, n := utf8.DecodeRuneInString(msg[from:to])
		if !edge(r) {
			break
		}
		from += n
	}
	for to > from {
		r, n := utf8.DecodeLastRuneInString(msg[from:to])
		if !edge(r) {
			break
		}
		to -= n
	}
	if from == to {
		return m
	}
	return mdMark{m.style, from, to}
}

// checkedMarkdown renders marks, and returns the result only if reading it back
// gives exactly the text and the styles meant. Italics are tried as * and then
// as _, which does not run together with the ** of bold.
func checkedMarkdown(msg string, marks []mdMark) (string, bool) {
	if len(marks) == 0 {
		return msg, true
	}
	for _, italic := range []string{"*", "_"} {
		md, plain, want := renderMarks(msg, marks, italic)
		got, styles, err := parseMarkdown(md)
		if err == nil && got == plain && sameStyles(styles, want) {
			return md, true
		}
	}
	return "", false
}

// mdMark is one styled stretch of a received message, in bytes.
type mdMark struct {
	style       string
	start, stop int
}

// styleMarks turns the ranges Signal sent into byte ranges of msg, merged per
// style. SPOILER, anything unknown and anything out of range are dropped.
func styleMarks(msg string, styles []textStyle) []mdMark {
	if len(styles) == 0 {
		return nil
	}
	at := unitOffsets(msg)
	units := len(at) - 1

	byStyle := map[string][][2]int{}
	for _, s := range styles {
		switch s.Style {
		case styleBold, styleItalic, styleStrike, styleMono:
		default:
			continue
		}
		if s.Start < 0 || s.Length <= 0 || s.Start >= units {
			continue
		}
		from, to := at[s.Start], at[min(s.Start+s.Length, units)]
		if from < to {
			byStyle[s.Style] = append(byStyle[s.Style], [2]int{from, to})
		}
	}

	var marks []mdMark
	for style, spans := range byStyle {
		for _, s := range mergeSpans(spans) {
			marks = append(marks, mdMark{style, s[0], s[1]})
		}
	}
	sort.Slice(marks, func(i, j int) bool {
		if marks[i].start != marks[j].start {
			return marks[i].start < marks[j].start
		}
		return styleRank(marks[i].style) < styleRank(marks[j].style)
	})
	return marks
}

// renderMarks writes msg as Markdown with marks applied. Beside the Markdown it
// returns the plain text and styles that the Markdown is meant to read back as,
// which is what checkedMarkdown compares against.
func renderMarks(msg string, marks []mdMark, italic string) (md, plain string, want []textStyle) {
	w := &mdWriter{msg: msg, italic: italic}

	var blocks, inline []mdMark
	for _, m := range marks {
		if m.style == styleMono {
			// Line breaks at either end stay outside the code.
			for m.start < m.stop && isLineBreak(msg[m.start]) {
				m.start++
			}
			for m.stop > m.start && isLineBreak(msg[m.stop-1]) {
				m.stop--
			}
			if m.start == m.stop {
				continue
			}
			if strings.IndexByte(msg[m.start:m.stop], '\n') >= 0 {
				blocks = append(blocks, m)
				continue
			}
		}
		inline = append(inline, m)
	}

	at := 0
	for _, b := range blocks {
		w.lines(at, b.start, inline)
		w.fence(b.start, b.stop)
		at = b.stop
	}
	w.lines(at, len(msg), inline)
	return w.md.String(), w.plain.String(), w.wanted()
}

// mdWriter builds the Markdown for a received message, and alongside it the
// plain text and styles that Markdown stands for.
type mdWriter struct {
	msg, italic string
	md, plain   strings.Builder
	want        []mdStyle // over plain, in bytes
}

// write adds text, the same in both, carrying the styles named.
func (w *mdWriter) write(s string, styles ...string) {
	for _, style := range styles {
		w.want = append(w.want, mdStyle{style, w.plain.Len(), w.plain.Len() + len(s)})
	}
	w.md.WriteString(s)
	w.plain.WriteString(s)
}

// mark adds a marker, which only the Markdown has.
func (w *mdWriter) mark(s string) {
	w.md.WriteString(s)
}

func (w *mdWriter) marker(style string) string {
	switch style {
	case styleBold:
		return "**"
	case styleItalic:
		return w.italic
	default:
		return "~~"
	}
}

// lines writes msg[from:to] a line at a time. Markers never run across a line
// break -- a blank line, or a list or quote starting, would end the paragraph
// they belong to -- so each line closes what it opened.
func (w *mdWriter) lines(from, to int, marks []mdMark) {
	for from < to {
		end := to
		if nl := strings.IndexByte(w.msg[from:to], '\n'); nl >= 0 {
			end = from + nl
		}
		w.line(from, end, marks)
		if end < to {
			w.write("\n")
			end++
		}
		from = end
	}
}

// line writes one line, msg[start:end], with its markers.
func (w *mdWriter) line(start, end int, marks []mdMark) {
	var on []mdMark
	for _, m := range marks {
		from, to := max(m.start, start), min(m.stop, end)
		if m.style != styleMono {
			// A marker has to sit against what it formats: "**word **" is not
			// bold. Space at either end stays outside it.
			from, to = trimSpace(w.msg, from, to)
		}
		if from < to {
			on = append(on, mdMark{m.style, from, to})
		}
	}
	if len(on) == 0 {
		w.write(w.msg[start:end])
		return
	}

	cuts := []int{start, end}
	for _, m := range on {
		cuts = append(cuts, m.start, m.stop)
	}
	sort.Ints(cuts)

	var open []mdMark // outermost first
	for k := 0; k+1 < len(cuts); k++ {
		p, q := cuts[k], cuts[k+1]
		if p == q {
			continue
		}
		mono := false
		var here []mdMark
		for _, m := range on {
			if m.start <= p && q <= m.stop {
				if m.style == styleMono {
					mono = true
				} else {
					here = append(here, m)
				}
			}
		}

		// Close what has ended -- and, to keep markers nested, whatever was
		// opened inside it. What is still going is opened again below.
		keep := 0
		for keep < len(open) && hasMark(here, open[keep]) {
			keep++
		}
		for i := len(open) - 1; i >= keep; i-- {
			w.mark(w.marker(open[i].style))
		}
		open = open[:keep]

		// Open what is not open, whichever lasts longest outermost.
		var opening []mdMark
		for _, m := range here {
			if !hasMark(open, m) {
				opening = append(opening, m)
			}
		}
		sort.Slice(opening, func(i, j int) bool {
			if opening[i].stop != opening[j].stop {
				return opening[i].stop > opening[j].stop
			}
			return styleRank(opening[i].style) < styleRank(opening[j].style)
		})
		for _, m := range opening {
			w.mark(w.marker(m.style))
			open = append(open, m)
		}

		styles := make([]string, 0, len(open)+1)
		for _, m := range open {
			styles = append(styles, m.style)
		}
		segment := w.msg[p:q]
		if !mono {
			w.write(segment, styles...)
			continue
		}
		// Code is innermost, always: nothing inside a code span is read as
		// Markdown. Where another style changes partway through, the code is
		// split into spans of its own, with the markers between them.
		fence, pad := codeSpanFence(segment)
		w.mark(fence + pad)
		w.write(segment, append(styles, styleMono)...)
		w.mark(pad + fence)
	}
	for i := len(open) - 1; i >= 0; i-- {
		w.mark(w.marker(open[i].style))
	}
}

// fence writes monospace that runs across lines as a fenced code block, which
// needs lines of its own: when the code starts or ends partway through a line,
// a line break is added there.
func (w *mdWriter) fence(start, stop int) {
	body := w.msg[start:stop]
	if start > 0 && w.msg[start-1] != '\n' {
		w.write("\n")
	}
	ticks := strings.Repeat("`", max(3, longestRun(body, '`')+1))
	w.mark(ticks + "\n")
	w.write(body, styleMono)
	w.mark("\n" + ticks)
	if stop < len(w.msg) && w.msg[stop] != '\n' {
		w.write("\n")
	}
}

// wanted is the styles the Markdown stands for, as markdownToSignal reports
// them.
func (w *mdWriter) wanted() []textStyle {
	units := utf16Offsets([]byte(w.plain.String()))
	out := make([]textStyle, 0, len(w.want))
	for _, s := range w.want {
		if s.start < s.stop {
			out = append(out, textStyle{s.style, units[s.start], units[s.stop] - units[s.start]})
		}
	}
	return normalizeStyles(out)
}

// codeSpanFence picks the backticks for a code span: one more than the longest
// run inside it. And a space of padding where the content would lose an edge
// without one -- a backtick at either end would join the fence, and CommonMark
// strips a space from both ends when both have one.
func codeSpanFence(s string) (fence, pad string) {
	fence = strings.Repeat("`", longestRun(s, '`')+1)
	if strings.HasPrefix(s, "`") || strings.HasSuffix(s, "`") ||
		(strings.HasPrefix(s, " ") && strings.HasSuffix(s, " ") && strings.Trim(s, " ") != "") {
		pad = " "
	}
	return fence, pad
}

// ---------------------------------------------------------------- shared

// utf16Offsets maps every byte position in s to the UTF-16 offset it falls at.
// A position inside a character falls at that character's start.
func utf16Offsets(s []byte) []int {
	at := make([]int, len(s)+1)
	n := 0
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRune(s[i:])
		for k := 0; k < size; k++ {
			at[i+k] = n
		}
		n++
		if r >= 0x10000 {
			n++ // a surrogate pair
		}
		i += size
	}
	at[len(s)] = n
	return at
}

// unitOffsets maps every UTF-16 offset into s to the byte it falls on. The
// second half of a surrogate pair falls on its character's first byte.
func unitOffsets(s string) []int {
	at := make([]int, 0, len(s)+1)
	for i, r := range s {
		at = append(at, i)
		if r >= 0x10000 {
			at = append(at, i)
		}
	}
	return append(at, len(s))
}

// normalizeStyles merges overlapping and touching ranges of the same style and
// orders the result, so the same formatting always comes out the same.
func normalizeStyles(styles []textStyle) []textStyle {
	byStyle := map[string][][2]int{}
	for _, s := range styles {
		if s.Length > 0 {
			byStyle[s.Style] = append(byStyle[s.Style], [2]int{s.Start, s.Start + s.Length})
		}
	}
	var out []textStyle
	for style, spans := range byStyle {
		for _, s := range mergeSpans(spans) {
			out = append(out, textStyle{style, s[0], s[1] - s[0]})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Start != out[j].Start {
			return out[i].Start < out[j].Start
		}
		if out[i].Style != out[j].Style {
			return styleRank(out[i].Style) < styleRank(out[j].Style)
		}
		return out[i].Length < out[j].Length
	})
	return out
}

// mergeSpans sorts intervals and joins the ones that overlap or touch.
func mergeSpans(spans [][2]int) [][2]int {
	sort.Slice(spans, func(i, j int) bool { return spans[i][0] < spans[j][0] })
	var out [][2]int
	for _, s := range spans {
		if n := len(out); n > 0 && s[0] <= out[n-1][1] {
			out[n-1][1] = max(out[n-1][1], s[1])
			continue
		}
		out = append(out, s)
	}
	return out
}

func sameStyles(a, b []textStyle) bool {
	a, b = normalizeStyles(a), normalizeStyles(b)
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func styleRank(style string) int {
	switch style {
	case styleBold:
		return 0
	case styleItalic:
		return 1
	case styleStrike:
		return 2
	case styleMono:
		return 3
	}
	return 4
}

func hasMark(marks []mdMark, m mdMark) bool {
	for _, x := range marks {
		if x == m {
			return true
		}
	}
	return false
}

// trimSpace narrows [from, to) of s past whitespace at either end.
func trimSpace(s string, from, to int) (int, int) {
	for from < to {
		r, n := utf8.DecodeRuneInString(s[from:to])
		if !util.IsSpaceRune(r) {
			break
		}
		from += n
	}
	for to > from {
		r, n := utf8.DecodeLastRuneInString(s[from:to])
		if !util.IsSpaceRune(r) {
			break
		}
		to -= n
	}
	return from, to
}

func longestRun(s string, ch byte) int {
	longest, n := 0, 0
	for i := 0; i < len(s); i++ {
		if s[i] == ch {
			n++
			longest = max(longest, n)
		} else {
			n = 0
		}
	}
	return longest
}

func isLineBreak(b byte) bool {
	return b == '\n' || b == '\r'
}
