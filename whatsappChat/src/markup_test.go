package main

import "testing"

func TestToWhatsAppMarkup(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"plain text is untouched", "hello there, see you at 5", "hello there, see you at 5"},
		{"whatsapp markers are untouched", "*bold* _italic_ ~gone~ `code`", "*bold* _italic_ ~gone~ `code`"},
		{"markdown bold", "this is **important** ok", "this is *important* ok"},
		{"snake_case and dunder in prose stay", "call my_func and __init__.py", "call my_func and __init__.py"},
		{"markdown strike", "~~cancelled~~ moved", "~cancelled~ moved"},
		{"heading becomes a bold line", "## Release notes", "*Release notes*"},
		{"heading with bold inside", "# **Big** news", "*Big news*"},
		{"hashtag is not a heading", "#weekend plans", "#weekend plans"},
		{"link", "read [the docs](https://example.org/docs) first", "read the docs (https://example.org/docs) first"},
		{"link whose label is its url", "[https://example.org](https://example.org)", "https://example.org"},
		{"image", "![cat](https://example.org/cat.png)", "cat (https://example.org/cat.png)"},
		{"autolink", "<https://example.org>", "https://example.org"},
		{"non-web link is left as typed", "[x](javascript:alert(1))", "[x](javascript:alert(1))"},
		{"code span is not touched", "use `**kwargs` and **this**", "use `**kwargs` and *this*"},
		{"unclosed backtick is a backtick", "a ` b **c**", "a ` b *c*"},
		{"fence loses its language", "```go\nx := **y**\n```", "```\nx := **y**\n```"},
		{"tilde fence becomes backticks", "~~~\n~~keep~~\n~~~\nafter ~~this~~", "```\n~~keep~~\n```\nafter ~this~"},
		{"unclosed fence protects the rest", "```\n**raw**", "```\n**raw**"},
		{"lists and quotes stay", "- one\n1. two\n> three", "- one\n1. two\n> three"},
		{"bold across words", "**two words**", "*two words*"},
		{"lone double star", "2 ** 3 = 8", "2 ** 3 = 8"},
	}
	for _, tc := range cases {
		if got := toWhatsAppMarkup(tc.in); got != tc.want {
			t.Errorf("%s:\n in:   %q\n got:  %q\n want: %q", tc.name, tc.in, got, tc.want)
		}
	}
}
