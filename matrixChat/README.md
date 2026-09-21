# Matrix for DMS

Connects DMS to a Matrix homeserver — Synapse, Conduit, Dendrite, or matrix.org
itself. Rooms, direct messages, attachments, replies and read receipts show up in
the DMS chat window, **including end-to-end encrypted rooms**.

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

Then enable **Matrix** under **Settings → Chats** and sign in there: the
provider's card asks for your homeserver, user id and password, in the same place
WhatsApp shows a QR code.

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
does. A new device has no keys to messages sent before it existed, so encrypted
history shows as undecryptable until the device is verified.

Matrix normally verifies a new device by asking you to confirm it on one you are
already signed in to. If DMS is your only signed-in client there is nothing to
confirm it from — Element offers "start verification on the other device" and
there is no other device.

So use your **recovery key** instead, under **Settings → Chats → Matrix →
Verify this device**. That is the key Element gave you when you turned on Secure
Backup; the passphrase you chose works there too. It unlocks secret storage on
your homeserver, which holds both the cross-signing keys that mark this device as
genuinely yours and the backup key that decrypts your history.

The key is sent to the bridge, used, and dropped. It is never written to plugin
settings or logged.

If the account has no Secure Backup, the field says so: turn it on in another
client first, and keep the recovery key it gives you.

Unencrypted rooms are readable immediately either way.

## What works

| | |
|---|---|
| Send and receive text | yes |
| End-to-end encrypted rooms | yes, via pure-Go olm |
| Replies | yes |
| Message edits | yes — the edit replaces the original in place |
| Images, video, audio, files | yes, including encrypted attachments |
| Formatted messages | yes — HTML bodies are passed through |
| Read receipts | yes, both ways — what you read elsewhere counts as read here |
| Rooms, with per-room display names | yes |
| Delete for everyone (redaction) | yes |
| Direct messages named after the other person | yes |
| Spaces | listed and taggable, but they are containers rather than conversations |
| Invitations | shown in the conversation list, and joined or declined from it |
| History before this device existed | unlock it with your recovery key, see below |
| Backfill of older messages | not yet — the room shows what has arrived since signing in |
| Search | local only — the DMS store indexes what it has received |
| Reactions, threads, calls, spaces as hierarchy | not modelled by the contract yet |

## What counts as unread

Matrix keeps your read position for every room, and every client of yours moves
it. The bridge reports it, so a room you read on your phone this morning is not
unread here this afternoon, and does not notify when the shell starts and the
conversation arrives.

Rooms read before this bridge learned to look are caught up on once, at the next
start — one filtered sync, recorded in `~/.local/share/dms-matrix/catchup` so no
later start repeats it.

Nothing is sent on your behalf: whether **you** send read receipts is still the
**Send read receipts** setting below, and turning it off only stops other people
seeing when you have read theirs.

## Invitations

An invitation to a room appears as an ordinary conversation tagged **invite**,
named after the room and saying who asked you. Open it and the composer is
replaced by the only two answers there are: **Join** (`Alt+Y`) or **Decline**
(`Alt+N`).

Joining enters the room and the conversation carries on as any other. Declining
leaves the room, forgets it, and removes it here — unless there is real history
in it from a previous stay, which is kept.

It works both ways round: an invitation accepted or declined in another client
stops being one here too, and one that arrives while the shell is closed is
waiting the next time it starts.

If you would rather not see them at all, turn **Show Invitations** off under the
chat filters below. That only hides them; nothing is answered on your behalf.

## Settings

Under **Settings → Chats → Matrix**:

- **Send read receipts** — off still clears your own unread count; it only stops
  telling the sender.
- **Download attachments automatically**, and a size limit above which they wait
  until you open them.
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
| Room names and pending invitations | `~/.local/share/dms-matrix/rooms.json` | matrixChat |
| Messages and conversations | `~/.local/share/DankMaterialShell/chat/history.db` | DMS |
| Cached attachments | `~/.cache/DankMaterialShell/chat/media/` | DMS |
| Plugin settings | `~/.config/DankMaterialShell/plugin_settings.json` | DMS |

**The session file is your account.** The token in it grants full access, and the
key beside it decrypts your message keys. Keep both out of dotfile repos and
shared backups.

**Sign out** in Settings → Chats logs the device out on the homeserver and
deletes all three files locally. The crypto store goes with the session
deliberately: keeping it would leave a later login inheriting keys for a device
that no longer exists.

## Troubleshooting

```sh
dms chat status matrixChat    # connection state, capabilities, restarts, recent stderr
dms chat tail matrixChat      # live protocol traffic, both directions
```

`tail` is the useful one: the bridge runs as a child of the daemon, so its output
is otherwise invisible.

| Symptom | Usually |
|---|---|
| Will not enable | The bridge is not built — run `./build.sh` |
| Stuck at "needsLogin" | No session, or the token was revoked. Sign in again from the provider's card |
| Sign-in says the password was not accepted | The homeserver's own words; check the user id form, `@you:example.org` |
| Rooms are named after their id | The name cache was lost; delete `rooms.json` and restart to rebuild it from the server |
| Messages say they cannot be decrypted | This device is not verified yet — enter your recovery key under Settings → Chats → Matrix |
| A room is missing | It may be filtered out; check **Chat filters**, especially Spaces and Low priority |
| Attachment will not open | `dms chat tail` shows the download error; encrypted media needs the room's keys |

If the homeserver revokes the token, the bridge stops rather than retrying
forever, clears the session and reports `needsLogin`, which puts the sign-in form
back in the provider's card.

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
