package chat

import (
	"regexp"
	"strings"
)

// ShortName is how a person or a conversation is called where there is room
// for little more than a name: a notification, one line wide on some setups.
//
// Names that reach the host are often not names at all. A Matrix account with
// no display name is "@whatsapp_lid-26139372290197:mjolnir.example.net"; a
// puppet a bridge made for a WhatsApp contact is "Ada Lovelace (WA)"; a client
// telling two Adas apart writes "Ada (@ada:example.org)". All of that is there
// to tell accounts apart, which a notification does not need to do -- and it
// took the line the message itself should have had.
//
// What is left is the name, or the shortest readable thing that stands for the
// account: a phone number, or the service and the last digits of its id. An
// email address is kept as it is: for a mail bridge it is the name.
func ShortName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}

	if m := matrixUserID.FindStringSubmatch(name); m != nil {
		return puppetName(m[1])
	}
	if m := whatsappJID.FindStringSubmatch(name); m != nil {
		return "+" + m[1]
	}

	short := name
	// Repeated, for "Ada (WA) (@ada:example.org)".
	for {
		trimmed := strings.TrimSpace(idSuffix.ReplaceAllString(short, ""))
		trimmed = strings.TrimSpace(bridgeSuffix.ReplaceAllString(trimmed, ""))
		if trimmed == short {
			break
		}
		short = trimmed
	}
	if short == "" {
		return name
	}
	return short
}

var (
	// A whole Matrix user id: "@local:server".
	matrixUserID = regexp.MustCompile(`^@([^:\s]+):\S+$`)

	// A WhatsApp address: "905551234567@s.whatsapp.net".
	whatsappJID = regexp.MustCompile(`^(\d{5,})@s\.whatsapp\.net$`)

	// An account id in brackets after a name, the way clients disambiguate:
	// "Ada (@ada:example.org)", "Ada [+905551234567]".
	idSuffix = regexp.MustCompile(`\s*[(\[]\s*(@[^\s)\]]+:[^\s)\]]+|\+?\d{6,})\s*[)\]]$`)

	// The tag a bridge puts after the names of the people it brings in.
	bridgeSuffix = regexp.MustCompile(`(?i)\s*[(\[]\s*(wa|whatsapp|telegram|tg|signal|discord|sms|instagram|ig|messenger|fb|facebook|slack|imessage|linkedin|twitter|gmessages|google messages|bluesky|meta)\s*[)\]]$`)

	// The accounts bridges make for the people they bring in: "whatsapp_<number>",
	// "whatsapp_lid-<id>", "signal_<uuid>", "telegram_<id>".
	puppetLocalpart = regexp.MustCompile(`^(whatsapp|signal|telegram|discord|instagram|meta|facebook|slack|gmessages|imessage|linkedin|twitter|bluesky)_(lid-)?([0-9a-zA-Z_=.\-]+)$`)
)

var serviceNames = map[string]string{
	"whatsapp":  "WhatsApp",
	"signal":    "Signal",
	"telegram":  "Telegram",
	"discord":   "Discord",
	"instagram": "Instagram",
	"meta":      "Messenger",
	"facebook":  "Messenger",
	"slack":     "Slack",
	"gmessages": "SMS",
	"imessage":  "iMessage",
	"linkedin":  "LinkedIn",
	"twitter":   "Twitter",
	"bluesky":   "Bluesky",
}

// puppetName makes something readable of a Matrix localpart: a bridged phone
// number as the number, any other bridged account as its service and the end
// of its id, and an ordinary account as itself.
func puppetName(localpart string) string {
	m := puppetLocalpart.FindStringSubmatch(localpart)
	if m == nil {
		return localpart
	}
	service, lid, rest := m[1], m[2], m[3]
	if service == "whatsapp" && lid == "" && isDigits(rest) {
		return "+" + rest
	}
	tail := strings.ReplaceAll(rest, "-", "")
	if len(tail) > 4 {
		tail = tail[len(tail)-4:]
	}
	return serviceNames[service] + " …" + tail
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
