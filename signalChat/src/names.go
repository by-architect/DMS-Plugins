package main

import (
	"strings"
)

// Conversation ids.
//
// The host treats an id as opaque and never parses it, but this bridge has to
// turn one back into something signal-cli understands, so the two kinds carry an
// explicit prefix. Guessing from shape -- a leading '+' means a phone number --
// works right up until a group id happens to start with one.
const (
	dmPrefix    = "dm:"
	groupPrefix = "grp:"
)

func directChatID(recipient string) string {
	return dmPrefix + recipient
}

func groupChatID(groupID string) string {
	return groupPrefix + groupID
}

func isGroupChat(chatID string) bool {
	return strings.HasPrefix(chatID, groupPrefix)
}

// recipientOf turns a conversation id back into send parameters.
//
// Returns the value and whether it names a group, because signal-cli takes the
// two through different parameters rather than one polymorphic field.
func recipientOf(chatID string) (value string, isGroup bool) {
	switch {
	case strings.HasPrefix(chatID, groupPrefix):
		return strings.TrimPrefix(chatID, groupPrefix), true
	case strings.HasPrefix(chatID, dmPrefix):
		return strings.TrimPrefix(chatID, dmPrefix), false
	default:
		// An id from before the prefixes existed, or one a user typed. Treating
		// it as a direct recipient is the harmless reading: signal-cli rejects
		// it if it is not one, rather than sending somewhere unintended.
		return chatID, false
	}
}

// contact is the shape signal-cli's listContacts returns.
type contact struct {
	Number            string `json:"number"`
	UUID              string `json:"uuid"`
	Username          string `json:"username"`
	Name              string `json:"name"`
	ProfileName       string `json:"profileName"`
	GivenName         string `json:"givenName"`
	FamilyName        string `json:"familyName"`
	Nickname          string `json:"nickName"`
	IsBlocked         bool   `json:"isBlocked"`
	IsSelf            bool   `json:"isSelf"`
	IsHidden          bool   `json:"isHidden"`
	MessageExpiration string `json:"messageExpirationTime"`
	Profile           struct {
		GivenName  string `json:"givenName"`
		FamilyName string `json:"familyName"`
	} `json:"profile"`
}

// group is the shape signal-cli's listGroups returns.
type group struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Description   string `json:"description"`
	IsMember      bool   `json:"isMember"`
	IsBlocked     bool   `json:"isBlocked"`
	IsArchived    bool   `json:"isArchived"`
	MessageExpiry int    `json:"messageExpirationTime"`
	Members       []struct {
		Number string `json:"number"`
		UUID   string `json:"uuid"`
	} `json:"members"`
}

// contactID picks the identifier to address this contact by.
//
// The UUID is preferred over the phone number because it is the one that does
// not change: Signal lets people change their number while keeping the account,
// and a conversation keyed on the number would split in two when they do.
func contactID(c contact) string {
	if c.UUID != "" {
		return c.UUID
	}
	return c.Number
}

// contactDisplayName picks the most human name available.
//
// The order matters: a nickname the user set themselves beats the name the
// contact chose for themselves, which beats a bare phone number.
func contactDisplayName(c contact) string {
	joined := strings.TrimSpace(strings.TrimSpace(c.GivenName) + " " + strings.TrimSpace(c.FamilyName))
	profile := strings.TrimSpace(strings.TrimSpace(c.Profile.GivenName) + " " + strings.TrimSpace(c.Profile.FamilyName))

	for _, candidate := range []string{
		strings.TrimSpace(c.Nickname),
		strings.TrimSpace(c.Name),
		joined,
		strings.TrimSpace(c.ProfileName),
		profile,
		strings.TrimSpace(c.Username),
	} {
		if candidate != "" {
			return candidate
		}
	}
	return strings.TrimSpace(c.Number)
}

// handlesFor lists everything a user might type to reach this conversation.
//
// This is what makes searching a phone number work. The host matches against
// these rather than picking an id apart, so a contact reachable by number, by
// username and by UUID is found by all three.
func handlesFor(c contact) []string {
	var out []string
	seen := map[string]bool{}

	for _, h := range []string{c.Number, c.Username, c.UUID} {
		h = strings.TrimSpace(h)
		if h == "" || seen[h] {
			continue
		}
		seen[h] = true
		out = append(out, h)
	}
	return out
}

// tagsFor labels a direct conversation.
//
// Only what the host cannot work out for itself: it already derives group,
// direct, unread, muted and archived. These two are Signal's own ideas.
func tagsFor(c contact, self string) []string {
	var tags []string
	if c.IsBlocked {
		tags = append(tags, "blocked")
	}
	if c.IsSelf || (self != "" && c.Number == self) {
		tags = append(tags, "noteToSelf")
	}
	return tags
}

func groupTagsFor(g group) []string {
	var tags []string
	if g.IsBlocked {
		tags = append(tags, "blocked")
	}
	if !g.IsMember {
		// Left or removed. Kept rather than dropped, because the history is
		// still yours to read; it is simply not somewhere you can write.
		tags = append(tags, "formerGroup")
	}
	return tags
}

func groupDisplayName(g group) string {
	if n := strings.TrimSpace(g.Name); n != "" {
		return n
	}
	return "Group"
}
