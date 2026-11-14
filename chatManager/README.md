# Chat Manager (chatManager)

The chat system as a plugin: one window and one message store, shared by every
provider.

## Why this exists

The chat system was built into a fork of DankMaterialShell — a `ChatService`
singleton, a Chats section in Settings, a modal wired into `DMSShell.qml`, and a
chat host inside the `dms` daemon. Upstream DMS has **none** of that, so running
it meant maintaining a shell fork and rebasing it forever.

This plugin is the same system with nothing left in the shell. It runs on stock
DMS.

## How it fits together

```
 chat-providers/<id>/plugin.json        type:"chat", bridge:["./bin/x"]
        │  spawned + supervised
        ▼
 bridge process ──NDJSON stdio──▶ bin/chat-managerd        (this plugin)
                                        │
                                        ├── stores/<provider>/history.db
                                        ├── media cache + GC
                                        └── desktop notifications
                                        │
                          unix socket, the same "chat.*" methods
                                        ▼
                             ChatLink.qml → ChatCore.qml
                                        ▼
                        ChatWindow.qml     ChatManagerSettings.qml
```

The wire protocol is the one from when the host lived inside `dms`, which is why
**provider bridges needed no changes at all**; it has since gained invitations,
below, which a provider that has no such notion simply never declares.

## What runs where

| Piece | Where |
|---|---|
| Message store, media cache, notifications, bridge supervision | `bin/chat-managerd` |
| Process supervision and the socket | `ChatLink.qml` |
| State, history paging, send/read/search | `ChatCore.qml` |
| The window | `ChatWindow.qml` and its components |
| Every setting | `ChatManagerSettings.qml` |

The daemon surface declares `IpcHandler { target: "chats" }`, so a keybind bound
to `dms ipc call chats toggle` works exactly as it did when the shell provided
that target itself.

```sh
dms ipc call chats toggle                   # the window, with the conversation list
dms ipc call chats popout "Ada"             # one conversation, by name, number or address
dms ipc call chats conversation whatsappChat "<id>"   # by provider and id
dms ipc call chats unread                   # the next conversation with something waiting
dms ipc call chats start matrixChat "@ada:example.org"   # start one, where the provider can
dms ipc call chats status                   # is the manager up, and what is enabled
```

`popout` asks which one you meant, in the popout itself, when a name matches
more than one conversation -- with the arrows and Enter, like every list here.

## What a notification says

Who in the title, what in the body, nothing else in either — some setups show
a notification as a single line, and every word of the title is a word less of
the message:

| | title | body |
|---|---|---|
| direct conversation | `Hamza Ayvaz` | the message |
| group | `Hamza Ayvaz · İYC Mersin 2025-2026 Er…` | the message |

It comes from the provider by name (`Matrix`, `Signal`, `WhatsApp`), so a
notification rule can quiet one service and not the others, and carries the
sender's picture (the conversation's, in a direct one) when it is cached — or
the photo, when that is what was sent.

Names are shortened for it: what is only there to tell accounts apart goes.
`Ada (WA)` is `Ada`; `Ada (@ada:example.org)` is `Ada`;
`@whatsapp_905551234567:server` is `+905551234567`; an account a bridge made
with nothing better to go by, `@whatsapp_lid-26139372290197:server`, is
`WhatsApp …0197`. Email addresses stay as they are.

## Notifications open their conversation

Clicking a chat notification opens that conversation in the popout; one that
stands for several conversations at once opens the window. The manager raises
every notification with a `default` action and remembers which conversation
each one is about, then listens on the session bus for the notification server
answering. A click is told to every connected shell as a `chat.open` event,
since it arrives from the notification server rather than through any request.

## Drafts

What is typed into a conversation stays with that conversation. Switching to
another one files it away, along with any staged attachment, and brings back
whatever was waiting there -- so Enter never sends a message meant for one
person to another. A message that fails to send is put back in the field, or
into its conversation's draft if you have moved on. Drafts live in memory: they
survive closing the window, not restarting the shell.

## Finding a message in a conversation

**Ctrl+Shift+F** opens a search bar over the open conversation. It searches
everything this device has kept of that conversation -- not only what is loaded
on screen -- and lists the matches newest first, the matching words in the
accent colour.

**Enter** (or a click) takes the conversation to a match and selects it; the
bar stays, and **↑** / **↓** go to the older and newer matches from there
(**Enter** and **Shift+Enter** too, or the arrows on the bar). Moving the
pointer over the list lights the row under it, the one Enter would take.

## Selecting a message with the mouse

Clicking a message selects it, the same selection **Ctrl+K** / **Ctrl+J** move,
so **Ctrl+R**, **Ctrl+Shift+C**, **Ctrl+E**, **Ctrl+T** and **Ctrl+Delete** act
on the message clicked. Clicking it again, or **Esc**, lets it go. What is
clickable inside a message keeps its own click: a picture or file opens, a
link opens, a quote goes to what it answers, and a reaction is added or taken
back. **Esc** closes the bar and leaves the
message found selected, so Ctrl+R answers it.

A match further up than what is loaded is reached by paging older messages in
above, so the conversation stays one piece from the match down to the newest
message. Past five thousand messages back it opens on a page of its own.

The search is the ordinary `chat.search`, kept to one conversation by naming
it; the provider's own server-side search is not asked, since it spans the
whole account:

```json
{"id":31,"method":"chat.search","params":{"query":"invoice","provider":"matrixChat","chatId":"!room:example.org","limit":200}}
```

## Mentions

Typing **@** at the start of a word opens a list of the people in the
conversation over the message box: **↑** / **↓** move through it, **Enter** or
**Tab** picks, **Esc** puts it away and leaves what was typed. The mouse works
too: moving over a row lights it, the same highlight the arrows move, and a
click picks it. Picking writes
`@Name` into the field -- or `@id`, when two people share the name -- so the
draft stays readable.

Who is offered comes from the provider, when it lists members (below), and
from whoever has written in what is loaded, on any service. On the way out a
name picked from the members becomes the mention the provider writes: for
Matrix a link to the person's matrix.to address, which the bridge sends as a
pill that notifies them. A name with no such markup -- a sender on a service
without members -- goes as the text it is. `mentions.js` holds the rules, and
`tests/tst_mentions.qml` pins them down.

## Formatting

Messages are rendered with their formatting: **bold**, *italic*,
~~strikethrough~~, `inline code`, fenced code blocks, headings, quotes,
bulleted and numbered lists (nested too), tables and links. Pictures in a
message are never loaded, and only http and https links can be opened.

Which markers mean what is the provider's to say, in its capabilities:

| Capability | The text is | Providers |
|---|---|---|
| `markdown` | Markdown: `**bold**`, `*italic*`, `~~strike~~`, `` `code` ``, ```` ``` ```` blocks, `#` headings, `>` quotes, `-` and `1.` lists, tables, `[label](https://…)` | Matrix, Signal |
| `whatsappMarkup` | WhatsApp's own: `*bold*`, `_italic_`, `~strike~`, `` `code` ``, ```` ```mono``` ````, quotes and lists | WhatsApp |
| neither | plain text, links clickable — what every message was before | anything else |

WhatsApp keeps its own dialect so that a `*word*` looks here the way it looks
on the phone, for every message already in the history as well as new ones;
`**double**` is read as bold there too, so Markdown typed into a WhatsApp chat
still comes out right.

**Typing it.** The message field grows with what you write: **Enter** sends,
**Shift+Enter** starts a new line (the field used to be a single line, so a
code block could not be typed and a pasted one arrived as one long line). The
bridge turns the text into whatever its service uses: Matrix sends formatted
HTML beside the Markdown, Signal sends its own style ranges, WhatsApp gets
`**bold**` as `*bold*`, headings as bold lines and links as `label (url)`.

Previews — the conversation list, a quoted reply, search results, desktop
notifications — show the text without its markers. Copying a message copies
it as written, markers and all.

`markdown.js` is the renderer, with its rules and its reasons in its own
comments, and `tests/tst_markdown.qml` pins it down — including the cases that
must stay plain: `snake_case_names`, `2*3*4` in WhatsApp, `#hashtags`, and
everything inside code.

## Providers

A chat provider — Matrix, WhatsApp, Signal — is **its own plugin**, installed
into `plugins/` like any other. That is deliberate: a provider can be added long
after this one, without touching it.

Each provider ships three things:

| | |
|---|---|
| `plugin.json` | ordinary manifest, plus a `bridge` argv the manager reads |
| a daemon surface | registers the provider with this plugin |
| a settings surface | **its own** settings, kept in its own page |

Enabling the provider's plugin is what starts its bridge; disabling it stops it.
Its settings stay with it and are handed to the manager on change — nothing
provider-specific is configured here.

A provider's daemon is tiny: it finds this plugin through
`pluginService.pluginDaemonInstances["chatManager"]` and calls
`registerProvider(id, settings)`. The manager supervises the bridge process
itself, so there is nothing for the provider to launch.

The manifest needs a component of some kind — a manifest with none is rejected by
DMS as invalid, which is what the daemon surface provides.

### Invitations

One addition to the contract as the fork's `docs/CHAT-PLUGINS.md` described it --
the host's side of it is `src/internal/host/protocol.go` -- for services where a
conversation can arrive as an invitation you have not answered.

A provider declares the `invites` capability, publishes such a conversation with
`"invite"` among its `tags`, and answers two calls:

```json
{"id":12,"method":"acceptInvite","params":{"chatId":"!room:example.org"}}
{"id":13,"method":"declineInvite","params":{"chatId":"!room:example.org"}}
```

The conversation window then offers **Join** and **Decline** in place of the
composer, since nothing can be sent into a conversation you are not in. A
declined one is removed locally as well — the provider stops mentioning it, so
nothing would ever update the row again — unless it holds messages somebody
actually wrote, which are kept.

An invitation answered on another device is reported with one event, and
removed by the same rule:

```json
{"event":"chatGone","chatId":"!room:example.org"}
```

An invitation has no messages of its own, and conversations that have never had
any activity stay out of the list. A bridge should therefore give one a `lastTs`
and a `lastText`, and may send the invitation itself as a `system` message so
the conversation does not open empty. `system` is what keeps it out of unread
counts and notifications.

### Where a conversation has been read

A provider that knows its own read position — a Matrix read receipt, a
server-side read marker, another client of the same account — puts it on the
conversation it publishes:

```json
{"event":"chat","chat":{"id":"!room:example.org","readUpTo":1755300000000}}
```

The store takes the later of that and its own, and recounts unread from the
messages themselves. It can therefore only ever settle a disagreement in the
direction of *already seen*, which is the direction that matters: a
conversation read on a phone this morning should not be waiting here this
afternoon.

The other direction is `markRead`, which tells the provider. Besides the
conversation and how far it has been read, the host lists the messages that
made read — incoming ones the unread count would have counted, newest first, at
most 300, looked up before the read position moves:

```json
{"id":7,"method":"markRead","params":{"chatId":"…","upTo":1755300000000,"messages":[{"id":"…","senderId":"…","ts":1755299990000}]}}
```

WhatsApp and Signal take read receipts by message, not by time, and a bridge
only remembers the messages that arrived since it last started; the store
remembers them all. Without the list, reading anything older than the last
restart sent no receipt at all. A bridge should still cope without
`messages`, which an older host does not send.

Unread is counted from what actually arrives. A message the store has seen
before -- bridges redeliver on reconnect, and a sync resends what came in live --
is not counted again and does not notify again, and one older than where the
conversation has been read is not counted at all.

Opening a conversation reads that position back out of the answer that carries
its messages -- `chat.history` replies with `readUpTo` and `unread` alongside the
page -- and marks the conversation read only once the page is here. Both halves
matter. The conversation list the shell holds is streamed only while a window is
open, so a conversation opened from the launcher would otherwise be placed by a
cache that can be hours old and cheerfully report nothing waiting; and marking it
read before asking would erase the very thing being asked for.

### Older history

A provider that can fetch older messages declares the `history` capability.
The conversation then offers to page past what this device has stored --
reaching the top of it, or opening one too short to scroll, asks for more --
and the host asks the provider instead of stopping where it happened to start
listening:

```json
{"id":21,"method":"history","params":{"chatId":"…","before":1755300000000,"limit":50}}
```

The bridge sends what it found as a batch marked `backfill`, then answers
whether there is anything older still:

```json
{"event":"messages","backfill":true,"messages":[…]}
{"id":21,"ok":true,"result":{"hasMore":true}}
```

The host waits for the answer -- on a lane of its own, so nothing else waits
with it -- makes sure the batch is stored, and pages again, so the page the
shell gets holds what was fetched. `hasMore: false` is the beginning, and is
remembered: that conversation is not asked again until the manager restarts.
A backfill batch is never counted as unread, whatever the read position says;
nobody is waiting on history. A provider without the capability is still asked
when the store has nothing older, without waiting, as before.

### Reactions

`reactions` is a provider where a message can carry them. It reports each one,
with its own id:

```json
{"event":"reaction","reaction":{"id":"$r","chatId":"…","messageId":"$m","key":"👍","senderId":"…","senderName":"Ada","fromMe":false,"ts":1755300000000}}
```

(and a `reactions` batch of them), and answers `react` with the new reaction's
id and `unreact` by taking one back:

```json
{"id":22,"method":"react","params":{"chatId":"…","messageId":"$m","key":"👍"}}
→ {"id":22,"ok":true,"result":{"reactionId":"$r"}}
{"id":23,"method":"unreact","params":{"chatId":"…","messageId":"$m","reactionId":"$r","key":"👍"}}
```

A reaction taken back elsewhere arrives as an ordinary `deleted` event naming
the reaction's id; the host knows a deletion can name a reaction. Reactions are
stored apart from messages, so an edit or a redelivery never loses them, and a
page of messages comes with them summed up per key -- how many, who, and
whether one is ours.

### Edits

`edit` is a provider that lets you change the text of a message you sent:

```json
{"id":24,"method":"edit","params":{"chatId":"…","messageId":"$m","text":"corrected"}}
```

Only text messages, and only your own: an edit is a whole new message on most
services, and a caption edited as plain text would turn a photo into words on
everyone else's screen. Edits arriving from the service carry `editedTs` on the
message, which the store goes by: an older copy of a message -- the original,
paged in after its correction -- never puts back text that was corrected, an
"edit" from anyone but the author is ignored, and the message stays where it
was written rather than where it was edited.

### Typing

`typing` is a provider that says who is typing, and passes on that you are:

```json
{"event":"typing","chatId":"…","users":["Ada"]}
{"id":25,"method":"typing","params":{"chatId":"…","typing":true}}
```

The whole list each time, empty when nobody is. It goes straight to the shell
as a `chat.typing` push -- never stored, and never waiting for a state update.
The shell says typing at most every few seconds while you type, and says it has
stopped when the field empties, the message goes, or you pause.

### Starting a conversation

`startChat` opens a conversation from whatever reaches it on that service -- a
user, a room address -- and answers with its id:

```json
{"id":26,"method":"startChat","params":{"handle":"@ada:example.org"}}
→ {"id":26,"ok":true,"result":{"chatId":"!room:example.org","name":"Ada"}}
```

What a handle is, and the words when it is not one, are the provider's. The
window offers it when the search box holds something that looks like an
address -- starting with `@`, `#` or `!` -- and `dms ipc call chats start
<provider> <handle>` does it from a keybind.

### Members, for mentions

`members` is a provider that can say who is in a conversation, for the "@"
picker, and how a mention of each is written:

```json
{"id":27,"method":"members","params":{"chatId":"!room:example.org"}}
→ {"id":27,"ok":true,"result":{"members":[{"id":"@ada:example.org","name":"Ada","mention":"[Ada](https://matrix.to/#/@ada:example.org)","avatarPath":"/…/ada.jpg"}]}}
```

`mention` is the provider's own markup and goes into the message in place of
`@Name`; without it the name stays text. The shell asks with `chat.members`
(provider, chatId) when a conversation opens and again when a mention is
started. A provider without the capability answers with nobody, and the picker
offers whoever has written instead.

### Notification settings the service keeps

Some services keep notification settings of their own, shared by every client
of the account. A provider can pass them on per message, and both hints are
optional:

| On a message | Means |
|---|---|
| `"silent": true` | the service's settings would not notify for it -- a room set to mentions only, say. Stored and counted like any other; never a notification |
| `"highlight": true` | it mentions the user, and gets through even with group notifications off |

`mute` is a provider that also keeps a mute set here in step with its service:
muting a conversation in the window sends `setMuted` (chatId, muted), and a
conversation muted elsewhere arrives with `"muted": true` on its chat.

### The account, for the provider's own settings page

A provider can describe the account it is signed in to:

```json
{"event":"account","account":{"userId":"@ada:example.org","verified":true}}
```

The host keeps the latest and hands it over as `account` on the provider's
status, untouched -- what is in it is between the bridge and its own settings
page. `null` is signed out.

### Notifications wait for the sync to finish

A bridge that has just connected is not reporting news. It is replaying what
happened while nobody was listening, and every one of those messages looks live
to a host that only knows when it arrived — which is how a reconnect turns into
twenty notifications for conversations already dealt with.

So messages that arrive before a provider reports `connected` are held, and
judged a few seconds after it does: anything the provider says has since been
read is dropped, and what is left is announced **one notification per
conversation** — the newest message, with "(3)" beside the name — for at most five
conversations, with the rest counted in a single line. A provider that never
reports connected is flushed anyway after 45 seconds, and one switched off
loses whatever it was holding rather than notifying about it later.

Held messages are allowed to be up to half an hour older than the shell itself,
which is the difference between "you were away for a minute, here is what you
missed" and re-announcing yesterday's unread on every start. Live messages that
predate the shell are backfill and never notify at all.

This is also why a bridge should report `connected` again after recovering from
a failure, not only on its first sync: it is the signal that the catch-up is
over.

## Unread

```json
{"id":14,"method":"chat.unread","params":{"limit":200}}
→ {"id":14,"result":{"chats":[…],"messages":[…]}}
```

Both halves, because they answer different questions: the conversations are
what a cycle key steps through, and the messages — everything that arrived
after its conversation's read position — are what a search over unread text
matches on.

Two IPC verbs use it:

```sh
dms ipc call chats unread        # open the next conversation with something waiting
dms ipc call chats unreadStatus  # how much is waiting, without opening anything
```

`unread` cycles: oldest waiting first, one per press, wrapping at the end — a
backlog is worked from the bottom. The conversation opens at the first message
you had not seen, under a divider.

What had not been read when the conversation was opened is drawn in the
accent: a tint and a thin border on each message below the divider, kept for
as long as the conversation stays open, the way the divider is. In the
conversation list an unread conversation's name is in the accent too, unless
it is muted.

## Building

```sh
./build.sh
```

Needs Go. CGO is off — the SQLite driver is pure Go — so the binary runs
anywhere.

## Tests

```sh
./scripts/test
```

The manager's Go tests, a parse check over every QML file, and the QtTest suites
in `tests/`, run on the Qt that quickshell itself is built on -- key handling
differs between Qt releases, and an older Qt lying around in the Nix store once
failed paste tests that pass in the shell. The QML here cannot be loaded outside DMS, so what the suites cover
is what stands on its own and has been wrong before: the rules a message's links
go through (`links.js`), and the key behaviour the whole keymap rests on — which
chords a focused text field takes for itself, checked against every state a
half-written message can be in. Each part is skipped with a note if its tool is
missing.

## Where the messages live

Each provider gets its own database:

```
~/.local/share/DankMaterialShell/chat/stores/<providerId>/history.db
```

One provider's conversations are never in another's file, so removing a provider
is deleting one directory, and a query for one provider cannot see another's
rows. Upgrading from the single `history.db` splits it automatically on first
run; the old file is kept as `history.db.migrated` rather than deleted.

Switching a provider off hides its conversations everywhere -- window, launcher,
unread counts -- but does not delete them. Turning it back on brings the history
back.

## Resource cost

The manager only streams state while the window or the popout is open. Closing
them unsubscribes, so a shell sitting idle all day with chats closed does no work
per arriving message beyond what the bridge and the store already do.

A conversation that is open is refreshed on every push, and the refresh is
merged into what is on screen rather than replacing it: older pages you scrolled
back to stay, the selection follows its message, and a push that changed nothing
in this conversation changes nothing on screen.

The message list follows the same rule. Its rows are kept by message id and
changed one at a time -- a row added where a message arrived, one removed where
one went -- rather than the whole list being handed a new array on every push.
A list given a new array throws every row away and lays them out again from
wherever it last thought it was, which is what made the view jump up and down
after opening at the unread divider and whenever something arrived while
reading. Now the view stays put: a page of older messages grows the list
upwards without moving what is on screen, and the view follows the newest
message only while it is at the bottom. Scrolling in any way -- wheel,
touchpad glide, dragging, the scrollbar -- ends any claim on where the view
belongs until you come back down to the end.

## Requests that wait on a provider

Everything the shell asks goes down one socket, and most of it is a quick read
of the store, answered in the order it arrived. What waits on a provider --
sending, editing, reacting, fetching an attachment or an older page, signing
in, switching a provider on -- is answered on a lane of its own, so a photo
being uploaded does not freeze switching conversation or the launcher's
lookups. Requests on the same lane
still keep their order: two messages sent into one conversation never overtake
each other.
