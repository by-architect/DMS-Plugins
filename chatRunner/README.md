# Chat Runner

Every conversation, from every chat provider, in one list.

Type `c ` in the launcher, then a name, a phone number or an address. WhatsApp,
Signal, mail, KDE Connect SMS and anything else you have installed appear
together, ranked by how well they match. Selecting a row opens that
conversation.

With nothing typed, the list is ordered by what is waiting: conversations with
unread messages first, the one somebody wrote in last at the top. Typing puts
the match first again — a name you asked for outranks a name that happens to
have written — and what is unread only breaks the ties.

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

## Only what is waiting

Type `c unread` and the list becomes what you have not got to yet — every
conversation with something unread, whichever service it is on:

```
Ada Lovelace        3 unread  ·  are we still on for friday?   ·  Matrix
#release            1 unread  ·  Bea: tagged 2.1               ·  Matrix
```

Anything after the word searches **inside** those messages rather than across
every conversation: `c unread invoice` finds the unread message that mentions an
invoice, and says which conversation it is in. Selecting a row opens that
conversation at the first message you had not seen.

For working through them without the launcher, bind a key to
`dms ipc call chats unread`, which steps to the next unread conversation each
time it is pressed.

## Sending something, rather than opening something

Type `c share` and the same conversations are listed, but picking one **sends**
into it instead of opening it:

```
c share             →  Ada Lovelace   ·  Send "https://example.com/…"  ·  WhatsApp
                       #release       ·  Send "https://example.com/…"  ·  Matrix
```

What gets sent is whatever is on the clipboard, and anything after the word
searches the conversations as usual: `c share ada` goes straight to the person
you meant. There is no compose step — the clipboard is the message — and a
notification afterwards says where it went.

Most of the time you arrive here without typing it: the [clipboard
runner][clipboardrunner] offers **Share to a chat…** for whatever you copied,
and picking it opens the launcher on exactly this list. That route also carries
**files** — a copied image included, which it has already written out to disk —
and those are sent as attachments. Typed by hand, `c share` reads the
clipboard's text and nothing else.

A conversation whose provider cannot take what is being sent is not listed,
rather than listed and failing after the launcher has closed. A handoff from the
clipboard runner expires after two minutes, because by then it describes a
clipboard you have moved on from.

[clipboardrunner]: ../clipboardRunner/README.md

## What it can find

Matching happens in the backend, so this plugin knows nothing about any
particular service:

| You type | Matches |
|---|---|
| `Ada` | a conversation name |
| `unread` | only conversations with something waiting |
| `share` | every conversation, to send the clipboard into one |
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
