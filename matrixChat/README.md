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
./login.sh
```

Then enable **Matrix** under **Settings → Chats**.

The plugin refuses to enable until both steps are done, and says which one is
outstanding rather than sitting silently at "disconnected".

## Why signing in is a script

Matrix has no QR code to scan. Signing in means a password, and a password has no
business being in `plugin_settings.json` — that file is ordinary config, readable
by anything that can read your home directory.

So `./login.sh` asks in a terminal, exchanges the password for an access token
immediately, and stores **only the token**, in a file readable by you alone. The
password is never written anywhere.

This is also why the **Sign in** button in Settings cannot do it: there is
nothing for it to show. Pressing it resumes an existing session, and otherwise
points you back here.

## Encrypted history, and the one thing to know

**Signing in creates a new device**, exactly as adding Element on a new phone
does. A new device has no keys to messages sent before it existed, so encrypted
history will show as undecryptable until you **verify this device** from a client
already signed in to your account:

> Element → Settings → Security & Privacy → verify this session

After verifying, key sharing backfills what your other devices can see.
Unencrypted rooms are readable immediately either way.

This is Matrix working as designed, not a gap in the bridge. Any client would
behave the same.

## What works

| | |
|---|---|
| Send and receive text | yes |
| End-to-end encrypted rooms | yes, via pure-Go olm |
| Replies | yes |
| Message edits | yes — the edit replaces the original in place |
| Images, video, audio, files | yes, including encrypted attachments |
| Formatted messages | yes — HTML bodies are passed through |
| Read receipts | yes |
| Rooms, with per-room display names | yes |
| Delete for everyone (redaction) | yes |
| Direct messages named after the other person | yes |
| Spaces | listed and taggable, but they are containers rather than conversations |
| Invitations | shown, so you can see you have been invited |
| History before this device existed | encrypted rooms need device verification first |
| Backfill of older messages | not yet — the room shows what has arrived since signing in |
| Search | local only — the DMS store indexes what it has received |
| Reactions, threads, calls, spaces as hierarchy | not modelled by the contract yet |

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
| Will not enable | The bridge is not built, or you have not run `./login.sh` — the message says which |
| Stuck at "needsLogin" | No session, or the token was revoked. Run `./login.sh` again |
| Rooms are named after their id | The first sync is still filling in state; it settles within a few seconds |
| Messages say they cannot be decrypted | This device is not verified yet — verify it from Element |
| A room is missing | It may be filtered out; check **Chat filters**, especially Spaces and Low priority |
| Attachment will not open | `dms chat tail` shows the download error; encrypted media needs the room's keys |

If the homeserver revokes the token, the bridge stops rather than retrying
forever, clears the session and reports `needsLogin`. Run `./login.sh` again.

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
