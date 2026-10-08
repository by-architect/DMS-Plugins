package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// sentText sends text the way the composer does and returns what went out.
func sentText(t *testing.T, text, replyTo string) *event.MessageEventContent {
	t.Helper()
	sender := &fakeSender{}
	if _, err := testBridge().sendText(context.Background(), sender, testRoom, text, replyTo); err != nil {
		t.Fatalf("send: %v", err)
	}
	if len(sender.sent) != 1 {
		t.Fatalf("sent %d events, want 1", len(sender.sent))
	}
	return sender.sent[0]
}

// received converts a message from Ada carrying a formatted body.
func received(t *testing.T, body, formatted string) *messageObj {
	t.Helper()
	content := &event.MessageEventContent{MsgType: event.MsgText, Body: body}
	if formatted != "" {
		content.Format = event.FormatHTML
		content.FormattedBody = formatted
	}
	evt := msgEvent(testAda, content)
	msg := testBridge().convert(evt, content, evt.ID)
	if msg == nil {
		t.Fatal("the message did not convert")
	}
	return msg
}

// ---------------------------------------------------------------- outbound

// Markdown typed in the composer reaches Matrix formatted: the Markdown as the
// body, for clients that show plain text, and its HTML beside it.
func TestMarkdownIsSentFormatted(t *testing.T) {
	cases := map[string]string{
		"**bold**":                 "<strong>bold</strong>",
		"```go\nx := 1\n```":       "<pre><code class=\"language-go\">x := 1\n</code></pre>",
		"- one\n- two":             "<ul>\n<li>one</li>\n<li>two</li>\n</ul>",
		"1. one\n2. two":           "<ol>\n<li>one</li>\n<li>two</li>\n</ol>",
		"[DMS](https://dms.local)": `<a href="https://dms.local">DMS</a>`,
		"~~gone~~ and `code`":      "<del>gone</del> and <code>code</code>",
	}
	for typed, html := range cases {
		content := sentText(t, typed, "")
		if content.MsgType != event.MsgText {
			t.Errorf("%q: msgtype = %q", typed, content.MsgType)
		}
		if content.Body != typed {
			t.Errorf("%q: body = %q, want the Markdown as typed", typed, content.Body)
		}
		if content.Format != event.FormatHTML || content.FormattedBody != html {
			t.Errorf("%q: format = %q, formatted_body = %q, want %q", typed, content.Format, content.FormattedBody, html)
		}
	}
}

// Text that formats nothing goes without HTML, as Element sends it. mautrix's
// own verdict would have sent every one of these as HTML: an entity, a quote
// mark or a second line is enough for it.
func TestPlainTextIsSentPlain(t *testing.T) {
	for _, typed := range []string{
		"hello",
		"Tom & Jerry",
		`she said "hi"`,
		"a < b > c",
		"line one\nline two",
		"first paragraph\n\nsecond paragraph",
		"snake_case_name and 2 * 3",
		`C:\Users\ada`,
		"it's https://example.org",
	} {
		content := sentText(t, typed, "")
		if content.Body != typed {
			t.Errorf("%q: body = %q", typed, content.Body)
		}
		if content.Format != "" || content.FormattedBody != "" {
			t.Errorf("%q: plain text went out formatted: %q %q", typed, content.Format, content.FormattedBody)
		}
	}
}

// HTML typed into a message is text: it goes escaped, never as markup.
func TestTypedHTMLIsSentEscaped(t *testing.T) {
	content := sentText(t, `<b>not bold</b> <img src=x onerror=alert(1)> but **this is**`, "")
	want := "&lt;b&gt;not bold&lt;/b&gt; &lt;img src=x onerror=alert(1)&gt; but <strong>this is</strong>"
	if content.FormattedBody != want {
		t.Errorf("formatted_body = %q, want %q", content.FormattedBody, want)
	}

	// On its own it formats nothing, so it is plain text and shows as typed.
	content = sentText(t, "<script>alert(1)</script>", "")
	if content.Format != "" || content.Body != "<script>alert(1)</script>" {
		t.Errorf("format = %q, body = %q", content.Format, content.Body)
	}
}

// A backslash escape is Markdown too: the body says \*this\*, and the HTML
// says what it shows, *this* -- what Element sends for it.
func TestEscapesAreSentAsWhatTheyShow(t *testing.T) {
	content := sentText(t, `\*not italic\*`, "")
	if content.Body != `\*not italic\*` || content.FormattedBody != "*not italic*" {
		t.Errorf("body = %q, formatted_body = %q", content.Body, content.FormattedBody)
	}
}

func TestFormattedReplyKeepsItsRelation(t *testing.T) {
	content := sentText(t, "**yes**", "$question")
	if got := content.RelatesTo.GetReplyTo(); got != "$question" {
		t.Errorf("reply = %q", got)
	}
	if content.FormattedBody != "<strong>yes</strong>" || content.Body != "**yes**" {
		t.Errorf("body = %q, formatted_body = %q", content.Body, content.FormattedBody)
	}
}

// A caption is Markdown like any message; a file without one is named by its
// body, as before.
func TestCaptionIsSentFormatted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "photo.png")
	if err := os.WriteFile(path, []byte("png bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	send := func(caption string) *event.MessageEventContent {
		sender := &fakeSender{}
		if _, err := testBridge().sendFile(context.Background(), sender, testRoom, path, caption, "", false); err != nil {
			t.Fatalf("send: %v", err)
		}
		return sender.sent[0]
	}

	content := send("look at **this**")
	if content.Body != "look at **this**" || content.FileName != "photo.png" {
		t.Errorf("body = %q, filename = %q", content.Body, content.FileName)
	}
	if content.Format != event.FormatHTML || content.FormattedBody != "look at <strong>this</strong>" {
		t.Errorf("format = %q, formatted_body = %q", content.Format, content.FormattedBody)
	}

	for _, caption := range []string{"just words", ""} {
		content = send(caption)
		if content.Format != "" || content.FormattedBody != "" {
			t.Errorf("caption %q went out formatted: %q", caption, content.FormattedBody)
		}
	}
	if content.Body != "photo.png" {
		t.Errorf("uncaptioned body = %q, want the file name", content.Body)
	}
}

// ---------------------------------------------------------------- inbound

// A formatted message arrives as Markdown converted from its HTML, which is
// where the formatting is -- the body may have none, as here.
func TestFormattedMessageArrivesAsMarkdown(t *testing.T) {
	formatted := "<p><strong>bold</strong> and <em>it</em> and <code>a*b</code></p>\n" +
		"<pre><code class=\"language-go\">x := 1\n</code></pre>\n" +
		"<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n" +
		"<blockquote>\n<p>quoted</p>\n</blockquote>\n" +
		"<p><a href=\"https://example.org\">link</a> for <a href=\"https://matrix.to/#/@ada:example.org\">Ada</a></p>\n"
	msg := received(t, "bold and it and a*b x := 1 one two quoted link for Ada", formatted)

	want := "**bold** and *it* and `a*b`\n\n" +
		"```go\nx := 1\n```\n\n" +
		"* one\n* two\n\n" +
		"> quoted\n\n" +
		"[link](https://example.org) for @Ada"
	if msg.Text != want {
		t.Errorf("text =\n%s\nwant\n%s", msg.Text, want)
	}
	if msg.BodyHTML != formatted {
		t.Errorf("bodyHtml changed: %q", msg.BodyHTML)
	}
}

// A mention reads as the name it shows, never as a link to matrix.to.
func TestMentionsReadAsNames(t *testing.T) {
	msg := received(t, "Ada, bob, @carol: see #room:example.org",
		`<a href="https://matrix.to/#/@ada:example.org">Ada</a>, `+
			`<a href="https://matrix.to/#/@bob:example.org"></a>, `+
			`<a href="matrix:u/carol:example.org">@carol</a>: see `+
			`<a href="https://matrix.to/#/#room:example.org">#room:example.org</a>`)

	if want := "@Ada, @bob:example.org, @carol: see #room:example.org"; msg.Text != want {
		t.Errorf("text = %q, want %q", msg.Text, want)
	}
}

// A message without HTML is its body, character for character.
func TestPlainMessageKeepsItsBody(t *testing.T) {
	body := "**not converted**, <b>left</b> as\nit came: snake_case & 2*3"
	if msg := received(t, body, ""); msg.Text != body || msg.BodyHTML != "" {
		t.Errorf("text = %q, bodyHtml = %q", msg.Text, msg.BodyHTML)
	}
}

// HTML that converts to nothing -- an image without alt text, or only the
// quote of a reply -- leaves the body as the text rather than a blank bubble.
func TestEmptyConversionFallsBackToTheBody(t *testing.T) {
	for _, formatted := range []string{
		`<img src="mxc://example.org/emoji">`,
		"<p> </p>",
	} {
		if msg := received(t, "the body", formatted); msg.Text != "the body" {
			t.Errorf("%q: text = %q, want the body", formatted, msg.Text)
		}
	}
}

// mautrix's converter runs a table's cells together into one line, so a table
// arrives as its body: for one sent from here, the pipe table as typed.
func TestTableArrivesAsTheBody(t *testing.T) {
	body := "| a | b |\n|---|---|\n| 1 | 2 |"
	formatted := "<table>\n<thead>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n</thead>\n" +
		"<tbody>\n<tr>\n<td>1</td>\n<td>2</td>\n</tr>\n</tbody>\n</table>"
	if msg := received(t, body, formatted); msg.Text != body {
		t.Errorf("text = %q, want the body", msg.Text)
	}
}

// Text in the HTML stays text once it is Markdown: what would turn into
// formatting is escaped, and nothing else is. A newline inside a paragraph is
// a space, as HTML shows it; mautrix alone glued the words together.
func TestLiteralTextStaysLiteral(t *testing.T) {
	cases := []struct{ html, want string }{
		{
			`snake_case, 2 * 3, 2*3, _under_, \*star\*, a ~~ b, ` + "`tick`" + ` and C:\Users`,
			`snake_case, 2 * 3, 2\*3, \_under\_, \\\*star\\\*, a \~\~ b, \` + "`tick\\`" + ` and C:\Users`,
		},
		{"<p>line one\nline two</p>\n<p>next</p>", "line one line two\n\nnext"},
		{"a<br>\nb<br />c", "a\nb\nc"},
		{"<p><code>a*b_c</code> and</p><pre><code>x  *  y\n</code></pre>", "`a*b_c` and\n\n```\nx  *  y\n```"},
		{"<u>under</u>lined and un<em>believ</em>able<strong></strong>", "underlined and un*believ*able"},
	}
	for _, c := range cases {
		if msg := received(t, "body", c.html); msg.Text != c.want {
			t.Errorf("%q:\n got %q\nwant %q", c.html, msg.Text, c.want)
		}
	}
}

// Replies, edits and emotes are converted like any message.
func TestRepliesEditsAndEmotesAreConverted(t *testing.T) {
	b := testBridge()
	b.room(testRoom).Members[testAda] = "Ada"

	reply := &event.MessageEventContent{
		MsgType:       event.MsgText,
		Body:          "> <@bob:example.org> question\n\n**answer**",
		Format:        event.FormatHTML,
		FormattedBody: "<mx-reply><blockquote>question</blockquote></mx-reply><strong>answer</strong>",
		RelatesTo:     (&event.RelatesTo{}).SetReplyTo("$question"),
	}
	evt := msgEvent(testAda, reply)
	if msg := b.convert(evt, reply, evt.ID); msg.Text != "**answer**" || msg.ReplyTo != "$question" {
		t.Errorf("reply: text = %q, replyTo = %q", msg.Text, msg.ReplyTo)
	}

	edit := &event.MessageEventContent{
		MsgType:   event.MsgText,
		Body:      "* fixed",
		RelatesTo: &event.RelatesTo{Type: event.RelReplace, EventID: "$original"},
		NewContent: &event.MessageEventContent{
			MsgType: event.MsgText, Body: "fixed", Format: event.FormatHTML, FormattedBody: "<em>fixed</em>",
		},
	}
	evt = msgEvent(testAda, edit)
	if msg, isEdit := b.messageFor(evt, edit); !isEdit || msg.ID != "$original" || msg.Text != "*fixed*" {
		t.Errorf("edit: %v %q %q", isEdit, msg.ID, msg.Text)
	}

	// "* Ada waves" would be a list item in Markdown; the star is escaped.
	emote := &event.MessageEventContent{MsgType: event.MsgEmote, Body: "waves", Format: event.FormatHTML, FormattedBody: "<em>waves</em>"}
	evt = msgEvent(testAda, emote)
	if msg := b.convert(evt, emote, evt.ID); msg.Text != `\* Ada *waves*` {
		t.Errorf("emote = %q", msg.Text)
	}
	plain := &event.MessageEventContent{MsgType: event.MsgEmote, Body: "waves"}
	if msg := b.convert(evt, plain, evt.ID); msg.Text != `\* Ada waves` {
		t.Errorf("plain emote = %q", msg.Text)
	}
}

// mautrix sizes list numbers with a function that never returns for the
// smallest int64, and reads <ol start> with a parser that clamps to it: each
// of these, sent by anyone in any room, ended the bridge with a stack overflow
// no recover catches, and again after every restart. They arrive as their body
// instead. Without the guard, this test does not fail: it crashes.
func TestHostileListNumberingIsNotConverted(t *testing.T) {
	for _, formatted := range []string{
		`<ol start="-9223372036854775808"><li>x</li></ol>`,
		`<ol start="-9223372036854775807"></ol>`,
		`<ol start="9223372036854775807"><li>a</li><li>b</li></ol>`,
		`<ol start="-99999999999999999999"><li>x</li></ol>`,
		`<ol start="&#45;9223372036854775808"><li>x</li></ol>`,
		`<OL START=-9223372036854775808><LI>x</LI></OL>`,
		`<ol id=a start = '-9223372036854775808'><li>x</li></ol>`,
		// A decoy whose quoted value swallows the real attribute, for a scan
		// that searches on from each match.
		`start="<ol start="-9223372036854775808"><li>x</li></ol>`,
		// Cut off at the end: HTML drops this tag, but it is not worth relying on.
		`<ol start="-9223372036854775807`,
	} {
		if msg := received(t, "the body", formatted); msg.Text != "the body" {
			t.Errorf("%q: text = %q, want the body", formatted, msg.Text)
		}
	}

	// Lists that can be counted still convert, "start" in the text included.
	if msg := received(t, "body", `<p>start=5</p><ol start="999999999"><li>x</li><li>y</li></ol>`); msg.Text != "start=5\n\n999999999.  x\n1000000000. y" {
		t.Errorf("text = %q", msg.Text)
	}
}

// What is sent from here comes back -- the homeserver echoes every message to
// its sender -- as the Markdown it was typed as, so the conversation shows
// what was written.
func TestOwnMarkdownComesBackAsTyped(t *testing.T) {
	b := testBridge()
	for _, typed := range []string{
		"hello",
		"**bold** and *italic* and un*believ*able",
		"`code` and ~~gone~~",
		`\*literal\* stars and snake_case`,
		"line one\nline two **bold**",
		"> quoted\n\nanswer *now*",
		"```go\nx := 1\n```",
		"1. one\n2. two",
		"# Title",
		"[DMS](https://dms.local) and <https://example.org>",
		"| a | b |\n|---|---|\n| 1 | 2 |",
	} {
		content := sentText(t, typed, "")
		evt := msgEvent(testSelf, content)
		evt.ID = id.EventID("$echo")
		msg := b.convert(evt, content, evt.ID)
		if msg == nil {
			t.Fatalf("sent %q, and its echo did not convert", typed)
		}
		if msg.Text != typed {
			t.Errorf("sent %q, came back as %q", typed, msg.Text)
		}
	}
}

func TestEscapeMarkdown(t *testing.T) {
	cases := map[string]string{
		"plain words":   "plain words",
		"*":             `\*`,
		"a * b":         "a * b",
		"a*b":           `a\*b`,
		"snake_case":    "snake_case",
		"_lead":         `\_lead`,
		"tail_":         `tail\_`,
		"a ~ b ~~ c":    `a ~ b \~\~ c`,
		"`":             "\\`",
		`C:\dir`:        `C:\dir`,
		`a\*`:           `a\\\*`,
		`end\`:          `end\\`,
		"ümlaut_wörter": "ümlaut_wörter",
	}
	for in, want := range cases {
		if got := escapeMarkdown(in); got != want {
			t.Errorf("escapeMarkdown(%q) = %q, want %q", in, got, want)
		}
	}
	if strings.Contains(escapeMarkdown("x"), `\`) {
		t.Error("escaped a plain letter")
	}
}
