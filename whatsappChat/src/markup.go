package main

import (
	"regexp"
	"strings"
)

// WhatsApp formats with its own markers -- *bold*, _italic_, ~strike~,
// `code`, ```monospace```, "> " quotes, "- " and "1. " lists -- and the bridge
// declares "whatsappMarkup", so the chat window shows a WhatsApp message the
// way the phone does. What it shows *this* bridge's messages with is therefore
// already WhatsApp's own markup; nothing incoming needs converting.
//
// Outgoing text is another matter: the composer is shared with providers that
// speak Markdown, so whatever only Markdown means is rewritten into the
// WhatsApp equivalent before it is sent. Everything the two agree on -- _x_,
// `x`, quotes, lists -- and a single *x*, which is bold here and on the phone,
// is left exactly as typed. __x__ is left too: it is rare in a chat, and turning
// it into bold rewrote __init__.py. Code is never touched.

var (
	waFence       = regexp.MustCompile("^ {0,3}(`{3,}|~{3,})[ \\t]*[^`\\s]*[^`]*$")
	waHeading     = regexp.MustCompile(`^ {0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$`)
	waLink        = regexp.MustCompile(`!?\[([^\]\n]+)\]\((https?://[^\s()]+(?:\([^\s()]*\))?[^\s()]*)(?:[ \t]+"[^"\n]*")?\)`)
	waAutolink    = regexp.MustCompile(`<(https?://[^\s<>]+)>`)
	waStrongStars = regexp.MustCompile(`\*\*([^\s*](?:[^*]*?[^\s*])?)\*\*`)
	waStrike      = regexp.MustCompile(`~~([^\s~](?:[^~]*?[^\s~])?)~~`)
)

// toWhatsAppMarkup rewrites Markdown that WhatsApp would show as literal
// characters into WhatsApp's own markup.
func toWhatsAppMarkup(text string) string {
	lines := strings.Split(text, "\n")
	inFence := false
	fenceChar := byte(0)
	fenceLen := 0
	for i, line := range lines {
		if m := waFence.FindStringSubmatch(line); m != nil {
			marker := m[1]
			if !inFence {
				// WhatsApp's block monospace is plain ``` -- a language name
				// after it would arrive as the first line of the code.
				inFence, fenceChar, fenceLen = true, marker[0], len(marker)
				lines[i] = "```"
				continue
			}
			if marker[0] == fenceChar && len(marker) >= fenceLen && strings.TrimSpace(line) == marker {
				inFence = false
				lines[i] = "```"
				continue
			}
		}
		if inFence {
			continue
		}
		if h := waHeading.FindStringSubmatch(line); h != nil {
			// The whole line is bold, so bold inside it goes.
			if inner := strings.TrimSpace(strings.ReplaceAll(convertInline(h[1]), "*", "")); inner != "" {
				lines[i] = "*" + inner + "*"
			}
			continue
		}
		lines[i] = convertInline(line)
	}
	return strings.Join(lines, "\n")
}

// convertInline converts one line, leaving its code spans alone: a run of
// backticks up to the next run of the same length is copied verbatim.
func convertInline(line string) string {
	var out strings.Builder
	rest := line
	for rest != "" {
		start := strings.IndexByte(rest, '`')
		if start < 0 {
			out.WriteString(convertText(rest))
			break
		}
		out.WriteString(convertText(rest[:start]))
		run := 1
		for start+run < len(rest) && rest[start+run] == '`' {
			run++
		}
		ticks := rest[start : start+run]
		after := rest[start+run:]
		end := closingTicks(after, run)
		if end < 0 {
			// No closing run: the backticks are just backticks.
			out.WriteString(ticks)
			rest = after
			continue
		}
		out.WriteString(ticks)
		out.WriteString(after[:end])
		out.WriteString(ticks)
		rest = after[end+run:]
	}
	return out.String()
}

// closingTicks finds a run of exactly n backticks in s, or -1.
func closingTicks(s string, n int) int {
	for i := 0; i < len(s); {
		if s[i] != '`' {
			i++
			continue
		}
		j := i
		for j < len(s) && s[j] == '`' {
			j++
		}
		if j-i == n {
			return i
		}
		i = j
	}
	return -1
}

// convertText converts text that holds no code.
func convertText(s string) string {
	s = waLink.ReplaceAllStringFunc(s, func(m string) string {
		p := waLink.FindStringSubmatch(m)
		label, url := strings.TrimSpace(p[1]), p[2]
		if label == "" || label == url {
			return url
		}
		return label + " (" + url + ")"
	})
	s = waAutolink.ReplaceAllString(s, "$1")
	s = waStrongStars.ReplaceAllString(s, "*$1*")
	s = waStrike.ReplaceAllString(s, "~$1~")
	return s
}
