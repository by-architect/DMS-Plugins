package main

import (
	"reflect"
	"testing"

	"go.mau.fi/whatsmeow/types"
)

// Receipts come from what the host listed out of its store and from what
// arrived while the bridge was running: one per sender, each message once, and
// none that would name nobody.
func TestReadReceiptsMergeTheHostsListWithWhatArrived(t *testing.T) {
	group := types.NewJID("120363000000000000", types.GroupServer)
	ada := types.NewJID("111", types.DefaultUserServer)
	bob := types.NewJID("222", types.HiddenUserServer)
	cy := types.NewJID("333", types.DefaultUserServer)
	adaPhone := types.JID{User: "111", Device: 5, Server: types.DefaultUserServer}

	reported := []readMessage{
		{ID: "A", SenderID: adaPhone.String()}, // live, from a linked device
		{ID: "B", SenderID: "222@lid"},
		{ID: "C", SenderID: ""},                   // a group message with no sender
		{ID: "D", SenderID: "111@s.whatsapp.net"}, // the same person, from history
	}
	remembered := []unreadRef{
		{id: "A", sender: adaPhone, ts: 3000}, // listed by the host as well
		{id: "E", sender: cy, ts: 4000},       // not filed by the host yet
	}

	got := readReceipts(group, reported, remembered)
	want := []receipt{
		{sender: ada, ids: []types.MessageID{"A", "D"}},
		{sender: bob, ids: []types.MessageID{"B"}},
		{sender: cy, ids: []types.MessageID{"E"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("group receipts:\n got %+v\nwant %+v", got, want)
	}

	// A direct conversation's receipt goes to the conversation, so a message
	// from history, which carries no sender there, still gets one.
	got = readReceipts(ada, []readMessage{{ID: "X"}}, nil)
	want = []receipt{{sender: types.EmptyJID, ids: []types.MessageID{"X"}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("direct receipts:\n got %+v\nwant %+v", got, want)
	}

	// An older host lists nothing; what arrived here is all there is.
	got = readReceipts(ada, nil, []unreadRef{{id: "Y", sender: adaPhone, ts: 1000}})
	want = []receipt{{sender: ada, ids: []types.MessageID{"Y"}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("receipts without the host's list:\n got %+v\nwant %+v", got, want)
	}
}
