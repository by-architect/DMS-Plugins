package main

import (
	"context"
	"encoding/json"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/format"
	"maunium.net/go/mautrix/id"
)

// Mentions: who can be mentioned in a room, and a mention picked from them
// going out as one Matrix knows is a mention.
//
// Typing "@" in the composer opens a picker of the room's members. What it
// puts in the message is a Markdown link to the member's matrix.to address --
// the member's "mention" below -- which renders to the same <a> pill Element
// sends. setText then lists the user in m.mentions, which is what notifies
// them on a current homeserver, and writes the name alone in the plain body,
// which is what a notification on a phone shows.

// memberObj is one member as the host's members call wants it.
type memberObj struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Mention    string `json:"mention"`
	AvatarPath string `json:"avatarPath,omitempty"`
}

// handleMembers answers who is in a room: everyone joined or invited, as far
// as this bridge has seen, by the name they have in that room -- not us.
//
// Only what is already known. A large room is synced with its members lazily,
// so somebody who has not spoken may be missing; the shell adds whoever has
// written in the room from the messages it has.
func (b *bridge) handleMembers(_ context.Context, c call) {
	var params struct {
		ChatID string `json:"chatId"`
	}
	_ = json.Unmarshal(c.Params, &params)
	if params.ChatID == "" {
		fail(c.ID, "bad_request", "chatId is required")
		return
	}

	ok(c.ID, map[string]any{"members": b.membersOf(id.RoomID(params.ChatID))})
}

// membersOf lists a room's members, sorted by name.
func (b *bridge) membersOf(roomID id.RoomID) []memberObj {
	type known struct {
		user   id.UserID
		name   string
		avatar id.ContentURI
	}

	b.mu.RLock()
	self := b.selfIDLocked()
	var found []known
	if info, ok := b.rooms[roomID]; ok {
		found = make([]known, 0, len(info.Members))
		for user, name := range info.Members {
			if user == self {
				continue
			}
			found = append(found, known{user: user, name: strings.TrimSpace(name), avatar: info.MemberAvatars[user]})
		}
	}
	b.mu.RUnlock()

	members := make([]memberObj, 0, len(found))
	for _, k := range found {
		name := k.name
		if name == "" || name == string(k.user) {
			name = fallbackName(k.user)
		}
		members = append(members, memberObj{
			ID:         string(k.user),
			Name:       name,
			Mention:    mentionOf(name, k.user),
			AvatarPath: b.cachedAvatar(k.avatar),
		})
	}
	sort.Slice(members, func(i, j int) bool {
		a, z := strings.ToLower(members[i].Name), strings.ToLower(members[j].Name)
		if a != z {
			return a < z
		}
		return members[i].ID < members[j].ID
	})
	return members
}

// cachedAvatar is a picture's path when it has already been fetched, and ""
// otherwise. Never fetched from here: listing a room of a thousand would be a
// thousand downloads nobody is going to look at.
func (b *bridge) cachedAvatar(uri id.ContentURI) string {
	if uri.IsEmpty() || !b.settingBool("showAvatars", true) {
		return ""
	}
	path := b.avatarPath(uri)
	if path == "" {
		return ""
	}
	if info, err := os.Stat(path); err == nil && info.Size() > 0 {
		return path
	}
	return ""
}

// mentionOf is how a mention of a user is written in a message: a Markdown
// link to their matrix.to address, labelled with their name, the way mautrix
// writes one.
func mentionOf(name string, user id.UserID) string {
	return format.MarkdownMentionWithName(name, user)
}

// userMentionLink is a Markdown link to a user's matrix.to address: the label,
// with Markdown escapes in it, and the user id.
var userMentionLink = regexp.MustCompile(`\[((?:[^\[\]\\]|\\.)*)\]\(\s*<?https://matrix\.to/#/(@[^)\s>]+)>?\s*\)`)

// markdownEscape is a backslash before ASCII punctuation, which Markdown reads
// as the character itself.
var markdownEscape = regexp.MustCompile("\\\\([!-/:-@\\[-`{-~])")

// withMentions fills in what a message mentioning users needs beside its
// formatted body: the users in m.mentions, and a plain body that reads the
// way the message looks -- the names, not the links to them.
//
// Only links written as a mention of a user count: a matrix.to link to a room
// or a message is left as it was typed. A message mentioning nobody is left
// without m.mentions at all, so a homeserver still notices a display name
// typed out by hand, the way it did before.
func withMentions(content *event.MessageEventContent, typed string) {
	links := userMentionLink.FindAllStringSubmatch(typed, -1)
	if len(links) == 0 {
		return
	}
	var users []id.UserID
	for _, link := range links {
		user := id.UserID(unescapeMentionPart(link[2]))
		if _, _, err := user.Parse(); err != nil {
			continue
		}
		if !containsUser(users, user) {
			users = append(users, user)
		}
	}
	if len(users) == 0 {
		return
	}
	content.Mentions = &event.Mentions{UserIDs: users}
	content.Body = userMentionLink.ReplaceAllStringFunc(typed, func(link string) string {
		parts := userMentionLink.FindStringSubmatch(link)
		if _, _, err := id.UserID(unescapeMentionPart(parts[2])).Parse(); err != nil {
			return link
		}
		return markdownEscape.ReplaceAllString(parts[1], "$1")
	})
}

// unescapeMentionPart is a user id as written in a link: mautrix escapes the
// underscores and the like in one for Markdown, and anything a URL cannot
// carry as it is comes percent-encoded.
func unescapeMentionPart(s string) string {
	s = markdownEscape.ReplaceAllString(s, "$1")
	if decoded, err := url.PathUnescape(s); err == nil {
		return decoded
	}
	return s
}

func containsUser(users []id.UserID, user id.UserID) bool {
	for _, u := range users {
		if u == user {
			return true
		}
	}
	return false
}
