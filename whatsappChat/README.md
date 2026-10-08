# WhatsApp for DMS

Connects DMS to WhatsApp as a **linked device**, the same way WhatsApp Web and the desktop app do.
Your conversations, media, replies and read receipts show up in the DMS chat window.

This is a DMS *chat plugin*: it ships a small program called a **bridge** rather than QML. The
bridge translates WhatsApp into newline-delimited JSON and hands it to the **Chat Manager** plugin
(`chatManager`), which owns the message store, unread counts, the attachment cache, notifications
and search. The contract is `chatManager/src/internal/host/protocol.go`, with the additions
described in `chatManager/README.md`.

## Requirements

- The **Chat Manager** plugin, which runs the bridge and provides the chat window.
- **Go**, to build the bridge. It is not shipped prebuilt because it has to be compiled for your
  machine.
- A phone with WhatsApp, to link the device.

## Install

```bash
git clone <this repo> ~/.config/DankMaterialShell/plugins/whatsappChat
cd ~/.config/DankMaterialShell/plugins/whatsappChat
./build.sh
```

Then enable **WhatsApp Chat** under **Settings → Plugins**, with Chat Manager enabled as well. Its
options — history sync, attachment downloads, chat filters — are in its own settings page there.
Signing in happens in the chat window: open it, and it shows a QR code to scan with your phone under
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
| Read state synced from your phone | yes |
| Groups, with sender names | yes |
| Delete for everyone | yes |
| History backfill on first link | yes, optional |
| Search | local only — the DMS store indexes messages; WhatsApp has no server-side search |
| Reactions, polls, calls, status updates | not modelled by the contract yet |

Channels (newsletters), statuses and broadcast lists are not dropped: each is tagged, and **Chat
filters** in this plugin's settings hides any of them from the conversation list and the chat
runner. Hidden is only hidden — search still finds them, and nothing is deleted.

## Formatting

WhatsApp formats with its own markers -- `*bold*`, `_italic_`, `~strike~`,
`` `code` ``, ```` ```monospace``` ````, `> ` quotes and `- ` or `1. ` lists --
and the bridge declares `whatsappMarkup`, so the chat window shows a message
the way the phone does.

The message field is shared with Matrix and Signal, which speak Markdown, so
what only Markdown means is rewritten before sending (`src/markup.go`):
`**bold**` becomes `*bold*`, `~~strike~~` becomes `~strike~`, a `# heading`
becomes a bold line, `[label](https://…)` becomes `label (https://…)`, and a
code fence loses its language name. Everything both agree on is sent as typed,
and code is never touched.

## Where your data lives

| What | Where | Who owns it |
|---|---|---|
| WhatsApp session (the linked device itself) | `~/.local/share/dms-whatsapp/session.db`, mode 0600 | this plugin |
| Messages and conversations | `~/.local/share/DankMaterialShell/chat/stores/whatsappChat/history.db` | Chat Manager |
| Cached attachments | `~/.cache/DankMaterialShell/chat/media/whatsappChat/` | DMS |
| Plugin settings | `~/.config/DankMaterialShell/plugin_settings.json` | DMS |

**The session database is your WhatsApp account.** Anyone who can read it can read your messages.
It is created 0600 in a 0700 directory; keep it out of dotfile repos and backups you share.

To unlink, remove the device on your phone under *Linked devices* — there is no Sign out button in
the chat window. It then offers to sign in again. Deleting `~/.local/share/dms-whatsapp/` locally
leaves the device still linked on WhatsApp's side.

## Attachments

Media is not downloaded during history sync — a year of photos would be gigabytes nobody asked
for. Instead WhatsApp's own embedded thumbnail is shown immediately, and the full file is fetched
only when you open it.

The bridge remembers the most recent 4000 attachments it has seen so it can fetch them on demand.
Past that, opening a very old attachment reports that it is no longer available; reopening the
conversation refreshes it.

## Debugging

Stock DMS has no `dms chat` command. The bridge is a plain program reading stdin and writing
stdout, though, so you can drive it directly without DMS involved at all. Switch the plugin off
first: two copies of the bridge on one session take turns knocking each other offline.

```bash
printf '%s\n' '{"id":1,"method":"configure","params":{"settings":{},"mediaDir":"/tmp"}}' \
  | ./bin/whatsapp-chat-bridge
```

That prints the handshake, then a live pairing QR string — or, for a device that is already
linked, the connection coming up.

## A note on trust

This bridge runs as your user, holds your WhatsApp session, and talks to WhatsApp's servers. So do
all DMS plugins — there is no sandbox. It uses [whatsmeow](https://github.com/tulir/whatsmeow), the
same library most third-party WhatsApp clients are built on.

Linking an unofficial client is not something WhatsApp formally supports. It works, and has for
years, but the risk of account action is yours to weigh.
