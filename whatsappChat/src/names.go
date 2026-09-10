package main

import (
	"context"

	"go.mau.fi/whatsmeow/types"
)

// Name resolution is its own file because WhatsApp has no single answer to
// "what is this called". A conversation may be a group with a subject, a saved
// contact, or a bare phone number that only ever announced a push name.

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
