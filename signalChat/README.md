# Signal for DMS

Connects DMS to Signal as a **linked device**, the same way Signal Desktop does. Your
conversations, groups, attachments, replies and read receipts show up in the DMS chat window.

This is a DMS *chat plugin*: it ships a small program called a **bridge** rather than QML. The
bridge translates Signal into newline-delimited JSON and hands it to the **Chat Manager** plugin
(`chatManager`), which owns the message store, unread counts, the attachment cache, notifications
and search. The contract is `chatManager/src/internal/host/protocol.go`, with the additions
described in `chatManager/README.md`.

The bridge does not implement Signal's protocol. It drives
[**signal-cli**](https://github.com/AsamK/signal-cli) as a child process and speaks JSON-RPC to
it — signal-cli holds the keys, the crypto and the protocol, and none of it is reimplemented
here. That is why this bridge has no Go dependencies at all.

## Requirements

- The **Chat Manager** plugin, which runs the bridge and provides the chat window.
- **signal-cli**, on your `PATH` or named by `SIGNAL_CLI`. This is what actually talks to Signal.
- **Go**, to build the bridge. It is not shipped prebuilt because it has to be compiled for your
  machine.
- A phone with Signal, to link the device.

## Install

```bash
git clone <this repo> ~/.config/DankMaterialShell/plugins/signalChat
cd ~/.config/DankMaterialShell/plugins/signalChat
./build.sh
```

Then enable **Signal Chat** under **Settings → Plugins**, with Chat Manager enabled as well. Its
options are in its own settings page there. Signing in happens in the chat window: open it, and it
shows a QR code to scan with your phone under *Settings → Linked devices → Link New Device*.

The plugin refuses to enable until both the bridge is built and signal-cli is installed, and says
which of the two is missing rather than sitting silently at "disconnected".

## An important limitation

**Signal keeps no message history on its servers.** A newly linked device starts empty and fills
up as messages arrive. Conversations from before you linked will not appear here, and no setting
can bring them back — this is Signal's design, not a gap in the bridge.

Your contacts and groups *do* appear immediately, so you can find and open a conversation before
anyone has written in it. It will simply have no messages in it yet.

This is the one real difference from the WhatsApp plugin, which backfills years of history on
first link.

## What works

| | |
|---|---|
| Send and receive text | yes |
| Replies | yes |
| Photos, video, voice notes, documents, stickers | yes |
| Read receipts (sent / delivered / read) | yes |
| Groups, with sender names | yes |
| Delete for everyone | yes |
| Message edits | yes — the edit replaces the original in place |
| Your own messages from other devices | yes |
| Read state synced from your phone | yes |
| History before linking | no — Signal does not store it |
| Search | local only — the DMS store indexes what it has received |
| Reactions, polls, calls, stories | not modelled by the contract yet |

Reactions are received but deliberately not shown. The contract has no reaction concept, and
turning each one into a message would fill a conversation with things nobody said.

## Settings

In this plugin's own settings page (**Settings → Plugins → Signal Chat**):

- **Send read receipts** — off still clears your own unread count; it only stops telling the sender.
- **Download attachments automatically**, and a size limit above which they wait until you open them.
  signal-cli itself still downloads every attachment as it arrives — Signal offers no way to fetch
  one later, so an attachment it skipped could never be opened — and these decide what is handed to
  the chat window straight away.
- **Receive stories** — off tells the server not to send them at all, since they are not displayed.
- **Device name** — how this machine appears under *Linked devices* on your phone.
- **Chat filters** — which categories appear in the conversation list and the chat runner. Hiding
  is only hiding: search still finds them and nothing is deleted.

## Where your data lives

| What | Where | Owner |
|---|---|---|
| Signal account — the linked device itself | `~/.local/share/signal-cli/` | signal-cli |
| Messages and conversations | `~/.local/share/DankMaterialShell/chat/stores/signalChat/history.db` | Chat Manager |
| Cached attachments | `~/.cache/DankMaterialShell/chat/media/signalChat/` | Chat Manager |
| Plugin settings | `~/.config/DankMaterialShell/plugin_settings.json` | DMS |

The signal-cli data directory **is** your Signal identity on this machine. Anyone who can read it
can read your messages. Keep it out of dotfile repos and shared backups.

Because it is signal-cli's own default location, the same account also works from the command
line — `signal-cli -a +yournumber listContacts` and so on — which is occasionally the fastest way
to establish whether a problem is Signal's or the bridge's.

There is no Sign out button in the chat window. To unlink, remove this machine under *Linked
devices* on your phone; the local account data stays in signal-cli's directory until you remove it.

## Troubleshooting

Stock DMS has no `dms chat` command. The quickest way to tell whether a problem is Signal's or the
bridge's is to try the same account with signal-cli from the command line, as above — with this
plugin switched off, since only one signal-cli can hold an account at a time. If signal-cli stops
on its own, the bridge exits with it and Chat Manager restarts both.

| Symptom | Usually |
|---|---|
| Will not enable | The bridge is not built, or signal-cli is not on `PATH` (or `SIGNAL_CLI`) — the message says which |
| Stuck at "connecting" | signal-cli is starting; it is a JVM program and the first run is slow |
| QR code never appears | signal-cli could not start linking; `signal-cli link`, with the plugin off, shows why |
| Linked, but no messages | Expected at first — Signal sends no history. Have someone message you |
| Conversations but no history | The same thing, and it is permanent for messages sent before linking |
| Attachment will not open | It may have expired on the server; Signal keeps them for a limited time |

If linking times out, the code expired — press **Get a new code** in the chat window for a fresh
one.

## Environment

Two variables, mostly for development:

- `SIGNAL_CLI` — path to the signal-cli executable, if it is not on `PATH`.
- `SIGNAL_CLI_DATA_DIR` — an alternative account store, so you can test against a throwaway
  account without touching your real one.

## A note on trust

Unlike some other bridges, this one is on comparatively firm ground: signal-cli is a long-standing
project, and linking a device is a supported Signal feature rather than something worked around.
Signal does not endorse third-party clients, but a linked device is exactly what Signal Desktop is.

The usual caveat still applies: this plugin runs as your user, with your permissions, and holds
your Signal session. So does every DMS plugin — there is no sandbox.
