package main

import (
	"context"

	"go.mau.fi/whatsmeow/types"
)

// Name resolution is its own file because WhatsApp has no single answer to
// "what is this called". A conversation may be a group with a subject, a saved
// contact, or a bare phone number that only ever announced a push name.

// phoneHandle is the phone number a conversation can be found by.
//
// WhatsApp addresses contacts by LID now, so the number is not in the id and
// has to be looked up through the session's own mapping. Groups have no number;
// neither does a contact whose mapping the session has never seen.
func (b *bridge) phoneHandle(jid types.JID) string {
	client := b.getClient()
	if client == nil || client.Store == nil {
		return ""
	}

	switch jid.Server {
	case types.GroupServer, types.NewsletterServer, types.BroadcastServer:
		return ""
	}

	// Already a phone-number address: use it directly.
	if jid.Server == types.DefaultUserServer {
		return "+" + jid.User
	}

	if jid.Server != types.HiddenUserServer || client.Store.LIDs == nil {
		return ""
	}

	pn, err := client.Store.LIDs.GetPNForLID(context.Background(), jid)
	if err != nil || pn.IsEmpty() {
		return ""
	}
	return "+" + pn.User
}

// handlesFor is the handle list for a conversation, empty when it has none.
func (b *bridge) handlesFor(jid types.JID) []string {
	if phone := b.phoneHandle(jid); phone != "" {
		return []string{phone}
	}
	return nil
}

// tagsFor says what kind of conversation an address is.
//
// WhatsApp mixes real conversations with statuses, channels and broadcast
// lists in the same list. They are all filtered out of the conversation list
// today; tagging them means the user can decide instead.
func tagsFor(jid types.JID) []string {
	switch jid.Server {
	case types.NewsletterServer:
		return []string{"channel"}
	case types.BroadcastServer:
		// WhatsApp models "my status" as a broadcast address with this user.
		if jid.User == "status" {
			return []string{"status"}
		}
		return []string{"broadcast"}
	case types.GroupServer:
		return []string{"group"}
	}
	return nil
}

// contactDisplayName picks what a person should be called, preferring what the
// user themselves chose over what the contact announced.
func contactDisplayName(info types.ContactInfo) string {
	switch {
	case info.FullName != "":
		return info.FullName
	case info.FirstName != "":
		return info.FirstName
	case info.BusinessName != "":
		return info.BusinessName
	case info.PushName != "":
		return info.PushName
	}
	return ""
}

// chatName is the display name for a conversation.
func (b *bridge) chatName(jid types.JID) string {
	client := b.getClient()
	if client == nil {
		return ""
	}

	ctx := context.Background()

	if jid.Server == types.GroupServer {
		if info, err := client.GetGroupInfo(ctx, jid); err == nil && info.Name != "" {
			return info.Name
		}
		// Falling back to the raw id would show a bare number; better to let
		// the host keep whatever name it already had.
		return ""
	}

	return b.contactName(jid, "")
}

// contactName resolves a person, preferring what the user themselves chose.
//
// Order matters: a saved contact name is what the user expects to see, a push
// name is what the sender chose to call themselves, and the bare user part is
// the last resort.
func (b *bridge) contactName(jid types.JID, pushName string) string {
	client := b.getClient()
	if client == nil {
		return pushName
	}

	if client.Store != nil && client.Store.Contacts != nil {
		if info, err := client.Store.Contacts.GetContact(context.Background(), jid); err == nil && info.Found {
			switch {
			case info.FullName != "":
				return info.FullName
			case info.FirstName != "":
				return info.FirstName
			case info.BusinessName != "":
				return info.BusinessName
			case info.PushName != "":
				return info.PushName
			}
		}
	}

	if pushName != "" {
		return pushName
	}
	return jid.User
}
