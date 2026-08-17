# Chat Runner

Every conversation, from every chat provider, in one list.

Type `c ` in the launcher, then a name, a phone number or an address. WhatsApp,
Signal, mail, KDE Connect SMS and anything else you have installed appear
together, ranked only by how well they match. Selecting a row opens that
conversation.

## Why the provider is written on every row

Two people can share a name. The same person can be on two services. A group
chat and a contact can be called the same thing. So every row states which
service it belongs to, alongside its unread count:

```
Ada Lovelace        WhatsApp  ·  2 unread
Ada Lovelace        Mail
Ada                 Echo Chat  ·  no messages yet
```

You tell them apart by reading the row, not by guessing.

## What it can find

Matching happens in the backend, so this plugin knows nothing about any
particular service:

| You type | Matches |
|---|---|
| `Ada` | a conversation name |
| `+90 555 123 45 67` | a phone number, in any formatting |
| `ada@example.com` | an email address |
| `whatsappChat:1847…@lid` | an exact conversation |

Numbers and addresses are matched against the **handles** a provider declares,
never by picking apart a conversation id — WhatsApp ids, for example, contain no
phone number at all.

Contacts you have never written to are listed too, so you can start a
conversation from here. Turn that off in settings if you would rather see only
chats with history.

## Requirements

A DMS build with chat support, and at least one chat provider plugin enabled
under **Settings → Chats**. With none, the runner says so rather than showing an
empty list.

## Settings

- **Maximum results** — how many conversations to list at once (default 40)
- **Include conversations with no messages** — whether contacts you have never
  messaged appear (default on)
