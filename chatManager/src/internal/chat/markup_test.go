package chat

import "testing"

func TestStripMarkup(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"plain", "see you at 5", "see you at 5"},
		{"markdown emphasis", "**Deploy** is *done* ~~maybe~~", "Deploy is done maybe"},
		{"whatsapp markers", "*Meeting* moved to _Thursday_ ~Wednesday~", "Meeting moved to Thursday Wednesday"},
		{"bold italic", "***both***", "both"},
		{"code span keeps its contents", "run `a*b*c` now", "run a*b*c now"},
		{"inline triple backticks", "```room 4B```", "room 4B"},
		{"fence lines go, code stays", "fix:\n```go\nx := 1\n```\nthanks", "fix:\nx := 1\nthanks"},
		{"heading", "## Release notes", "Release notes"},
		{"quote", "> quoted\n> > deeper", "quoted\ndeeper"},
		{"link", "read [the docs](https://example.org/docs)", "read the docs"},
		{"snake_case stays", "call my_function_name", "call my_function_name"},
		{"arithmetic stays", "2*3*4 and 5 * 3", "2*3*4 and 5 * 3"},
		{"hashtag stays", "#weekend", "#weekend"},
		{"lone markers stay", "a * b ~ c _ d", "a * b ~ c _ d"},
		{"emoji and non-latin survive", "*Selam* 👋 _dünya_", "Selam 👋 dünya"},
		{"escaped markers are literal, without their backslash", "\\* Ada waves, 2\\*3\\*4 and \\*not italic\\*", "* Ada waves, 2*3*4 and *not italic*"},
		{"a backslash before a letter stays", `C:\Users\neo`, `C:\Users\neo`},
		{"escapes inside code stay", "`a\\*b`", "a\\*b"},
	}
	for _, tc := range cases {
		if got := StripMarkup(tc.in); got != tc.want {
			t.Errorf("%s:\n in:   %q\n got:  %q\n want: %q", tc.name, tc.in, got, tc.want)
		}
	}
}
