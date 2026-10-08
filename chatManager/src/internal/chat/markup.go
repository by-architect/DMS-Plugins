package chat

import (
	"regexp"
	"strings"
)

// A message's text can carry formatting -- Markdown from Matrix and Signal,
// WhatsApp's own *bold* _italic_ ~strike~ -- which the window renders. A
// desktop notification cannot, and "**Deploy** is done" in a notification is
// noise, so the markers come off first.
//
// One stripper serves both: the two agree on nearly every marker, and where
// they differ (*x* is italic in one and bold in the other) the answer here is
// the same either way -- the marker goes, the word stays. It only ever takes
// markers off in pairs at word boundaries, so 2*3*4, snake_case and a lone
// "*" are left exactly as written.

var (
	mkFence     = regexp.MustCompile("^ {0,3}(`{3,}|~{3,})[^`]*$")
	mkHeading   = regexp.MustCompile(`^ {0,3}#{1,6}[ \t]+`)
	mkQuote     = regexp.MustCompile(`^ {0,3}>[ \t]?`)
	mkLink      = regexp.MustCompile(`!?\[([^\]\n]+)\]\((?:https?://)[^\s()]+(?:\([^\s()]*\))?[^\s()]*(?:[ \t]+"[^"\n]*")?\)`)
	mkCode      = regexp.MustCompile("(`+)([^`\n]+?)(`+)")
	mkDouble    = regexp.MustCompile(`(\*\*|~~)([^\s*~](?:[^\n]*?[^\s*~])?)(\*\*|~~)`)
	mkUnder2    = regexp.MustCompile(`(^|[^\w])__([^\s_](?:[^\n]*?[^\s_])?)__($|[^\w])`)
	mkSingleSt  = regexp.MustCompile(`(^|[^\w*])\*([^\s*](?:[^*\n]*?[^\s*])?)\*($|[^\w*])`)
	mkSingleUn  = regexp.MustCompile(`(^|[^\w_])_([^\s_](?:[^_\n]*?[^\s_])?)_($|[^\w_])`)
	mkSingleTil = regexp.MustCompile(`(^|[^\w~])~([^\s~](?:[^~\n]*?[^\s~])?)~($|[^\w~])`)
	mkEscape    = regexp.MustCompile("\\\\[!-/:-@\\[-`{-~]")
)

// StripMarkup returns text with its formatting markers removed.
func StripMarkup(text string) string {
	if !strings.ContainsAny(text, "*_~`#>[\\") {
		return text
	}
	lines := strings.Split(text, "\n")
	out := lines[:0]
	inFence := false
	for _, line := range lines {
		if mkFence.MatchString(line) {
			inFence = !inFence
			continue
		}
		if inFence {
			out = append(out, line)
			continue
		}
		line = mkHeading.ReplaceAllString(line, "")
		for mkQuote.MatchString(line) {
			line = mkQuote.ReplaceAllString(line, "")
		}
		out = append(out, stripInline(line))
	}
	return strings.Join(out, "\n")
}

func stripInline(s string) string {
	s = mkLink.ReplaceAllString(s, "$1")
	// Code first, and its contents are not looked at again: `a*b*c` is code.
	var codes []string
	s = mkCode.ReplaceAllStringFunc(s, func(m string) string {
		p := mkCode.FindStringSubmatch(m)
		if len(p[1]) != len(p[3]) {
			return m
		}
		codes = append(codes, p[2])
		return "\x00" + string(rune(len(codes)-1+0xE000)) + "\x00"
	})
	// A backslash-escaped marker (\* in Markdown) is a literal character, not
	// a marker: set aside like code, and put back without its backslash.
	var escaped []string
	s = mkEscape.ReplaceAllStringFunc(s, func(m string) string {
		escaped = append(escaped, m[1:])
		return "\x01" + string(rune(len(escaped)-1+0xE000)) + "\x01"
	})
	for i := 0; i < 3; i++ { // ***x*** is bold inside italic: a pass per layer
		s = mkDouble.ReplaceAllStringFunc(s, func(m string) string {
			p := mkDouble.FindStringSubmatch(m)
			if p[1] != p[3] {
				return m
			}
			return p[2]
		})
		s = mkUnder2.ReplaceAllString(s, "$1$2$3")
		s = mkSingleSt.ReplaceAllString(s, "$1$2$3")
		s = mkSingleUn.ReplaceAllString(s, "$1$2$3")
		s = mkSingleTil.ReplaceAllString(s, "$1$2$3")
	}
	for i, e := range escaped {
		s = strings.Replace(s, "\x01"+string(rune(i+0xE000))+"\x01", e, 1)
	}
	for i, c := range codes {
		s = strings.Replace(s, "\x00"+string(rune(i+0xE000))+"\x00", c, 1)
	}
	return s
}
