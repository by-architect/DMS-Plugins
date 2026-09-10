# WhatsApp for DMS

Connects DMS to WhatsApp as a **linked device**, the same way WhatsApp Web and the desktop app do.
Your conversations, media, replies and read receipts show up in the DMS chat window.

This is a DMS *chat plugin*: it ships a small program called a **bridge** rather than QML. The
bridge translates WhatsApp into newline-delimited JSON and hands it to the DMS backend, which owns
the message store, unread counts, the attachment cache, notifications and search. See
`docs/CHAT-PLUGINS.md` in the DankMaterialShell repository for the contract.

## Requirements

- **Go**, to build the bridge. It is not shipped prebuilt because it has to be compiled for your
  machine.
- A phone with WhatsApp, to link the device.

## Install

```bash
git clone <this repo> ~/.config/DankMaterialShell/plugins/whatsappChat
cd ~/.config/DankMaterialShell/plugins/whatsappChat
./build.sh
```

Then open **Settings → Chats**, enable **WhatsApp**, and scan the QR code with your phone under
*Settings → Linked devices → Link a device*.

The plugin refuses to enable until the bridge is built, and tells you so rather than sitting
silently at "disconnected".

## What works

| | |
|---|---|
| Send and receive text | yes |
| Replies | yes |
| Photos, video, voice notes, documents, stickers | yes |
| Read receipts (sent / delivered / read) | yes |
| Groups, with sender names | yes |
| Delete for everyone | yes |
| History backfill on first link | yes, optional |
| Search | local only — the DMS store indexes messages; WhatsApp has no server-side search |
| Reactions, polls, calls, status updates | not modelled by the contract yet |

Newsletters and broadcast lists are filtered out. They are feeds rather than conversations, and in
a busy account they bury everything else.

## Where your data lives

| What | Where | Who owns it |
|---|---|---|
| WhatsApp session (the linked device itself) | `~/.local/share/dms-whatsapp/session.db`, mode 0600 | this plugin |
| Messages and conversations | `~/.local/share/DankMaterialShell/chat/history.db` | DMS |
| Cached attachments | `~/.cache/DankMaterialShell/chat/media/whatsappChat/` | DMS |
| Plugin settings | `~/.config/DankMaterialShell/plugin_settings.json` | DMS |

**The session database is your WhatsApp account.** Anyone who can read it can read your messages.
It is created 0600 in a 0700 directory; keep it out of dotfile repos and backups you share.

To unlink, use *Sign out* in Settings → Chats, or remove the device from your phone. Deleting
`~/.local/share/dms-whatsapp/` locally leaves the device still linked on WhatsApp's side.

## Attachments

Media is not downloaded during history sync — a year of photos would be gigabytes nobody asked
for. Instead WhatsApp's own embedded thumbnail is shown immediately, and the full file is fetched
only when you open it.

The bridge remembers the most recent 4000 attachments it has seen so it can fetch them on demand.
Past that, opening a very old attachment reports that it is no longer available; reopening the
conversation refreshes it.

## Debugging

```bash
dms chat providers              # is it discovered, is it running
dms chat status whatsappChat    # state, capabilities, restart count, recent stderr
dms chat tail whatsappChat      # live protocol traffic in both directions
```

The bridge is also a plain program reading stdin and writing stdout, so you can drive it directly
without DMS involved at all:

```bash
printf '%s\n' '{"id":1,"method":"configure","params":{"settings":{},"mediaDir":"/tmp"}}' \
  | ./bin/whatsapp-chat-bridge
```

That prints the handshake, then a live pairing QR string.

## A note on trust

This bridge runs as your user, holds your WhatsApp session, and talks to WhatsApp's servers. So do
all DMS plugins — there is no sandbox. It uses [whatsmeow](https://github.com/tulir/whatsmeow), the
same library most third-party WhatsApp clients are built on.

Linking an unofficial client is not something WhatsApp formally supports. It works, and has for
years, but the risk of account action is yours to weigh.
