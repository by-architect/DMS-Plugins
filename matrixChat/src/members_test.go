package main

import (
	"strings"
	"testing"

	"maunium.net/go/mautrix/id"
)

// The picker lists everyone in the room but us, by the name they have there,
// with the mention that notifies them.
func TestMembersOfARoom(t *testing.T) {
	b := testBridge()
	b.updateRoom(testRoom, func(info *roomInfo) {
		info.Members[testSelf] = "Me"
		info.Members[testAda] = "Ada"
		info.Members["@bea_b:example.org"] = "@bea_b:example.org"
	})

	members := b.membersOf(testRoom)
	if len(members) != 2 {
		t.Fatalf("got %d members, want 2 (not ourselves): %+v", len(members), members)
	}
	if members[0].ID != string(testAda) || members[0].Name != "Ada" {
		t.Errorf("first member = %+v, want Ada first by name", members[0])
	}
	if members[0].Mention != "[Ada](https://matrix.to/#/@ada:example.org)" {
		t.Errorf("Ada's mention = %q", members[0].Mention)
	}
	// No display name: named the way a message from them would be.
	if members[1].Name != "bea_b" {
		t.Errorf("a member without a name is called %q, want bea_b", members[1].Name)
	}

	if got := b.membersOf("!unknown:example.org"); len(got) != 0 {
		t.Errorf("a room never seen has members %+v", got)
	}
}

// A mention picked in the composer goes out as a pill, the user in
// m.mentions, and the name alone in the plain body.
func TestSentMentionIsAMention(t *testing.T) {
	text := "hi " + mentionOf("Bea B.", "@bea_b:example.org") + ", and *you*"
	content := sentText(t, text, "")

	if content.Mentions == nil || len(content.Mentions.UserIDs) != 1 || content.Mentions.UserIDs[0] != id.UserID("@bea_b:example.org") {
		t.Fatalf("m.mentions = %+v, want @bea_b:example.org", content.Mentions)
	}
	if content.Body != "hi Bea B., and *you*" {
		t.Errorf("body = %q, want the name in place of the link", content.Body)
	}
	if !strings.Contains(content.FormattedBody, `<a href="https://matrix.to/#/@bea_b:example.org">Bea B.</a>`) {
		t.Errorf("formatted body = %q, want the pill", content.FormattedBody)
	}
}

// A message mentioning nobody carries no m.mentions, so a display name typed
// by hand still notifies the way it always did; and a matrix.to link to a room
// is a link, not a mention.
func TestNoMentionsLeavesTheMessageAlone(t *testing.T) {
	plain := sentText(t, "hello Ada", "")
	if plain.Mentions != nil {
		t.Errorf("a plain message has m.mentions %+v", plain.Mentions)
	}
	if plain.Body != "hello Ada" {
		t.Errorf("body = %q", plain.Body)
	}

	room := "see [the room](https://matrix.to/#/#lobby:example.org)"
	linked := sentText(t, room, "")
	if linked.Mentions != nil {
		t.Errorf("a link to a room is a mention: %+v", linked.Mentions)
	}
	if linked.Body != room {
		t.Errorf("body = %q, want it as typed", linked.Body)
	}
}

// The same user twice is one mention.
func TestMentionedTwiceIsOneMention(t *testing.T) {
	ada := mentionOf("Ada", testAda)
	content := sentText(t, ada+" and "+ada, "")
	if content.Mentions == nil || len(content.Mentions.UserIDs) != 1 {
		t.Fatalf("m.mentions = %+v, want Ada once", content.Mentions)
	}
	if content.Body != "Ada and Ada" {
		t.Errorf("body = %q", content.Body)
	}
}
