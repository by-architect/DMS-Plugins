# Matrix for DMS

Connects DMS to a Matrix homeserver — Synapse, Conduit, Dendrite, or matrix.org
itself. Rooms, direct messages, attachments, replies, reactions, edits, typing
and read receipts show up in the DMS chat window, **including end-to-end
encrypted rooms** — with the history before this device signed in, your
account's own notification settings, and room pictures.

This is a DMS *chat plugin*: it ships a small program called a **bridge** rather
than QML. The bridge translates Matrix into newline-delimited JSON and hands it
to the DMS backend, which owns the message store, unread counts, the attachment
cache, notifications and search. See `docs/CHAT-PLUGINS.md` in the
DankMaterialShell repository for the contract.

It talks to your homeserver directly over the Matrix client-server API using
[mautrix-go](https://github.com/mautrix/go) — no separate daemon, no bridge
account, no Synapse-side configuration. Any account you can log into with Element
works here.

## Requirements

- **Go**, to build the bridge. It is not shipped prebuilt because it has to be
  compiled for your machine.
- An account on a Matrix homeserver.

Nothing else. The bridge is built with `CGO_ENABLED=0` and the pure-Go olm
implementation, so encryption needs no libolm and no C toolchain.

## Install

```bash
git clone <this repo> ~/.config/DankMaterialShell/plugins/matrixChat
cd ~/.config/DankMaterialShell/plugins/matrixChat
./build.sh
```

Then enable **Matrix Chat** under **Settings → Plugins** and open the chat
window: its sign-in panel asks for your homeserver, user id and password, in the
same place WhatsApp shows a QR code.

The plugin refuses to enable until the bridge is built, and says so rather than
sitting silently at "disconnected".

## How signing in works

Matrix has no QR code to scan, so instead of a code the card shows a short form.
The bridge declares the fields it needs and DMS renders them — the shell knows
nothing about homeservers.

**What you type is never stored.** The values go through the socket to the
bridge, which exchanges them for an access token and drops them. Only the token
is written, in a file readable by you alone. The password is not saved, not
logged, and not put in `plugin_settings.json` — which is ordinary config,
readable by anything that can read your home directory, and no place for a
credential.

`./login.sh` does exactly the same thing from a terminal, if you would rather
sign in before enabling the plugin, or are working on the bridge outside DMS.

## Encrypted history, and how to unlock it

**Signing in creates a new device**, exactly as adding Element on a new phone
does. A new device has no keys to messages sent before it existed. Scrolling
back fetches them all the same (see "Older history" below); the ones it cannot
decrypt yet show as waiting, and are filled in once the device is verified.

An encrypted message that arrives but cannot be decrypted yet -- most of what a
new device sees in its first sync, or a message whose sender shared the key
late -- is not dropped. It shows in the conversation as *Waiting for this
message — it could not be decrypted yet*, a system line that is never counted
as unread and never notifies, and the bridge writes it down
(`undecryptable.json`, the newest 1000) and tries it again:

- as soon as a room key for it arrives, from the sender or forwarded by another
  device of yours;
- straight after you verify this device with your recovery key, which restores
  the key backup;
- every 15 minutes. Once this device has been verified with the recovery key,
  that also looks the missing keys up in your key backup, which your other
  devices keep adding to, and asks your other signed-in devices for them. An
  unverified device asks nobody: the answer would be a refusal, and a refused
  key can no longer be taken from the backup either.

When the key turns up, the real message replaces the placeholder in place. A
message that can never be decrypted -- the sender's device refused this one
the key, say -- says *This message could not be decrypted* instead. Reactions
and edits that cannot be decrypted show nothing; an edit is applied once it
can be.

Matrix normally verifies a new device by asking you to confirm it on one you are
already signed in to. If DMS is your only signed-in client there is nothing to
confirm it from — Element offers "start verification on the other device" and
there is no other device.

So use your **recovery key** instead, under **Verify this device** on the
plugin's own settings page (**Settings → Plugins → Matrix Chat**). That is the
key Element gave you when you turned on Secure Backup; the passphrase you chose
works there too. It unlocks secret storage on your homeserver, which holds both
the cross-signing keys that mark this device as genuinely yours and your key
backup. Verifying is what makes other people's clients trust this device and
share their keys with it; the backup is restored too, and every message still
waiting for its key is tried again with it.

The recovery key is sent to the bridge, used, and dropped. It is never written
to plugin settings or logged. The backup key it unlocks is kept, in the
encryption store beside the room keys it protects and encrypted the same way,
so that keys your other devices back up later can be fetched for messages
still waiting on them. If you verified before this version, verify once more
to let it do that.

If the account has no Secure Backup, the field says so: turn it on in another
client first, and keep the recovery key it gives you.

Unencrypted rooms are readable immediately either way.

## What works

| | |
|---|---|
| Send and receive text | yes |
| End-to-end encrypted rooms | yes, via pure-Go olm |
| Messages that cannot be decrypted yet | shown as waiting, and filled in when their key arrives — see above |
| Replies | yes — click the quote to go to what it answers |
| Message edits | yes, both ways — `Ctrl+E`, or `↑` in an empty box, edits your last message; edited messages say so |
| Reactions | yes, both ways — `Ctrl+T`, or press one under a message; encrypted in encrypted rooms |
| Typing | yes, both ways — "Ada is typing…" under the room's name |
| Images, video, audio, files | yes, including encrypted attachments |
| Formatted messages | yes — Markdown both ways, see "Formatting" below |
| Read receipts | yes, both ways — what you read elsewhere counts as read here |
| Rooms, with per-room display names and pictures | yes |
| Delete for everyone (redaction) | yes |
| Direct messages named after, and pictured as, the other person | yes |
| Spaces | listed and taggable, but they are containers rather than conversations |
| Invitations | shown in the conversation list, and joined or declined from it |
| Starting a direct chat, joining a room | yes — type `@name:server` or `#room:server` into the search box |
| History before this device existed | fetched as you scroll back — see "Older history" below |
| Messages missed while the shell was off | fetched when it comes back, even past the 50 a sync carries |
| Notification settings (All / Mentions / Mute) | followed — see "Notifications" below |
| Signing out | on this plugin's settings page |
| Search | local only — the DMS store indexes what it has received |
| Threads, calls, spaces as hierarchy | not modelled by the contract yet — a thread reply shows as a reply |

## Formatting

The bridge declares the `markdown` capability: message text is Markdown in
both directions, and the chat window renders it.

**What you send.** What you type is Markdown: `**bold**`, `*italic*`,
`~~strike~~`, `` `code` ``, code blocks, lists, quotes, headings, links and pipe
tables. It goes to Matrix the way Element sends it: the Markdown as typed is the
plain body, and its HTML goes beside it as the formatted body, so other clients
show it formatted. Text that formats nothing goes as plain text only. HTML you
type is not markup: it is escaped, and shows as typed. Captions on attachments
work the same way, and so do replies.

**What you receive.** A formatted message is converted from its HTML into
Markdown, since the HTML is where the formatting is. Some clients send no
Markdown in the plain body at all. Mentions read as `@Name`, room
aliases as `#room:server`, and links to a message as their matrix.to address.
Characters that only look like Markdown, like a `*` someone escaped, are kept
as text. A plain message is shown exactly as its body.

Some HTML has no Markdown equivalent. Underline shows as plain text, and a
spoiler shows as `||text||` without being hidden. A table arrives as the
message's plain body, because the converter cannot write tables. For a table
sent from DMS, that body is the pipe table as you typed it. A numbered list
starting at an absurd number (ten digits or more) also arrives as the plain
body. Converting it would crash the bridge, so the HTML is not converted.

## Older history

Scrolling to the top of a conversation fetches what came before it from the
homeserver, a page at a time — the whole room, as far back as your account may
see it, not just what has arrived since this device signed in. A conversation
too short to scroll fetches on its own. The homeserver's
`/timestamp_to_event` finds where to start; a homeserver without it is walked
back from the newest message instead, which is slower but gets there.

History is decrypted with whatever keys this device has, and what it has no key
for yet shows as *Waiting for this message* and is tried again like anything
else — so verifying the device with the recovery key fills in the history too.
None of it counts as unread, and none of it notifies.

The other kind of gap is fixed by itself. After time away, a sync brings each
room's newest 50 events and nothing before them; a busy room's messages from
the middle of that absence used to be simply missing. They are fetched right
after the sync, a couple of rooms at a time, up to a thousand messages a room.
Those can be unread — they arrived while nobody was looking — but they do not
notify: the newest ones already said there was something new.

## Notifications

Matrix keeps your notification settings on the homeserver, shared by every
client of the account, and DMS follows them: a room set to **Mentions and
keywords** in Element only notifies here when you are mentioned, a **muted**
room never does, and a message that mentions you gets through even if group
notifications are off in the Chat Manager's settings. Keywords and
**Disable notifications** for the whole account work the same way.

Mute goes both ways: a room muted in Element shows as muted here, and muting a
conversation here mutes the room in Element too. Turn **Follow my Matrix
notification settings** off below and DMS's own settings decide alone, as they
did before.

## Starting a conversation

Type an address into the chat window's search box: `@name:server` for a person
— a direct chat with them, or the one you already have — or `#room:server`
(or a `!room-id`) for a room to join. `Enter` opens it. The server can be left
off for someone on your own homeserver: `@ada` means `@ada:your.server`.

A new direct chat is created the way Element creates one: private, marked as a
direct chat for both of you, and encrypted from the start. Without encryption
working on this device it is not created at all.

```sh
dms ipc call chats start matrixChat "@ada:example.org"
```

## What counts as unread

Matrix keeps your read position for every room, and every client of yours moves
it. The bridge reports it, so a room you read on your phone this morning is not
unread here this afternoon, and does not notify when the shell starts and the
conversation arrives.

Rooms read before this bridge learned to look are caught up on once, at the next
start — one filtered sync, recorded in `~/.local/share/dms-matrix/catchup` so no
later start repeats it. The first start of the version with pictures runs it
once more, to find the pictures earlier versions never kept, and asks for the
picture of the other person in each direct chat.

The other direction works too: opening a conversation here posts a read receipt
for the newest message in it, so a room read on this machine stops being unread
on your phone. Matrix hangs a receipt on a message rather than on a moment, so
the receipt names the newest message the bridge has seen -- which is what any
other client does when you open a room and read to the bottom.

Nothing is sent on your behalf beyond that: whether **you** send read receipts
is still the **Send read receipts** setting below, and turning it off leaves
your own unread count working while other people stop seeing when you have read
theirs.

## Invitations

An invitation to a room appears as an ordinary conversation tagged **invite**,
named after the room and saying who asked you. Open it and the composer is
replaced by the only two answers there are: **Join** (`Ctrl+Y`) or **Decline**
(`Ctrl+N`).

Joining enters the room and the conversation carries on as any other. Declining
leaves the room, forgets it, and removes it here — unless there is real history
in it from a previous stay, which is kept.

It works both ways round: an invitation accepted or declined in another client
stops being one here too, and one that arrives while the shell is closed is
waiting the next time it starts.

If you would rather not see them at all, turn **Show Invitations** off under the
chat filters below. That only hides them; nothing is answered on your behalf.

## Settings

On the plugin's own settings page, **Settings → Plugins → Matrix Chat**:

- **Account** — who is signed in, on which homeserver and device, whether the
  device is verified and the key backup connected, how many messages are still
  waiting for their keys — and **Sign out**, after asking, optionally deleting
  the Matrix messages stored on this computer as well.
- **Send read receipts** — off still clears your own unread count; it only stops
  telling the sender.
- **Download attachments automatically**, and a size limit above which they wait
  until you open them.
- **Send typing notifications** — off still shows you when others are typing.
- **Follow my Matrix notification settings** — see "Notifications" above.
- **Show pictures** — room and profile pictures, fetched from your homeserver as
  small thumbnails.
- **Chat filters** — which categories appear in the conversation list and the
  chat runner. Hiding is only hiding: search still finds them and nothing is
  deleted.

## Where your data lives

| What | Where | Owner |
|---|---|---|
| Access token and device id | `~/.local/share/dms-matrix/session.json`, mode 0600 | matrixChat |
| Encryption keys | `~/.local/share/dms-matrix/crypto.db` | matrixChat |
| Sync position | `~/.local/share/dms-matrix/sync.json` | matrixChat |
| One-off catch-up marker | `~/.local/share/dms-matrix/catchup` | matrixChat |
| Room names, pictures' addresses, pending invitations, how far back history has been fetched | `~/.local/share/dms-matrix/rooms.json` | matrixChat |
| Room and profile pictures | `~/.cache/DankMaterialShell/chat/media/matrixChat/avatars/` | matrixChat, in DMS's cache |
| Messages waiting for their keys | `~/.local/share/dms-matrix/undecryptable.json`, mode 0600 | matrixChat |
| Messages and conversations | `~/.local/share/DankMaterialShell/chat/history.db` | DMS |
| Cached attachments | `~/.cache/DankMaterialShell/chat/media/` | DMS |
| Plugin settings | `~/.config/DankMaterialShell/plugin_settings.json` | DMS |

**The session file is your account.** The token in it grants full access, and the
key beside it decrypts your message keys. Keep both out of dotfile repos and
shared backups.

Signing out — the button on this plugin's settings page — logs the device out
on the homeserver and deletes the session, the crypto store, the sync position
and the room cache locally. Removing the DankMaterialShell session from another
client (Element: Settings → Sessions) does the same locally on the bridge's next
sync, and puts the sign-in form back. The crypto store goes with the session
deliberately: keeping it would leave a later login inheriting keys for a device
that no longer exists. The sync position goes too, because a new device resumed
from the old one's position never learns which rooms are encrypted. The list of
messages waiting for their keys stays: their placeholders are still in the
conversations, and signing back in to the same account and verifying can fill
them in. Signing in as somebody else starts it over.

## Troubleshooting

```sh
dms ipc call chats status    # is the chat manager up, and how many providers are on
quickshell log -f            # the manager's log, lines starting chat-managerd
```

The bridge runs as a child of the chat manager, which writes why a bridge would
not start, or keeps restarting, into the shell's log. Set
`DMS_CHAT_LOG_LEVEL=debug` in the shell's environment to see the bridge's own
output there too.

| Symptom | Usually |
|---|---|
| Will not enable | The bridge is not built — run `./build.sh` |
| Stuck at "needsLogin" | No session, or the token was revoked. Sign in again in the chat window, or with `./login.sh` |
| Sign-in says the password was not accepted | The homeserver's own words; check the user id form, `@you:example.org` |
| Rooms are named after their id | The first sync is still filling in state; it settles within a few seconds |
| Messages say *Waiting for this message* | This device does not have their key yet. Verify it with your recovery key: the backup is restored, other people's devices start sharing with it, and every waiting message is tried again. Keeping another of your devices (Element) signed in lets it answer this one's requests for missing keys |
| Scrolling up stops early | The homeserver says that is as far back as your account may see — rooms that only show history from when you joined |
| A room notifies although it is muted in Element | **Follow my Matrix notification settings** is off, or the shell started before the first sync brought the settings |
| A room is missing | It may be filtered out; check **Chat filters**, especially Spaces and Low priority |
| Attachment will not open | The download error is in the shell's log (`quickshell log`). Encrypted attachments received before the version that kept their key are opened by fetching their message again for it, which needs that message to be decryptable on this device. One that was already downloaded back then was saved still encrypted, and DMS keeps opening that copy |

If the homeserver revokes the token, the bridge stops rather than retrying
forever, clears the session and reports `needsLogin`, which puts the sign-in form
back in the chat window.

## Environment

One variable, mostly for development:

- `DMS_MATRIX_DIR` — an alternative session and crypto store, so you can test
  against a throwaway account without touching your real one.

## A note on trust

This is a normal Matrix client using a normal account, so there is nothing to
work around and no terms being stretched — unlike bridges to services that do not
want third-party clients.

The usual caveat still applies: this plugin runs as your user, with your
permissions, and holds a token granting full access to your Matrix account. So
does every DMS plugin — there is no sandbox.
