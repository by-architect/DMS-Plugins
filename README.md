# DMS Plugins

Plugins for [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell).

| Plugin | What it does |
|---|---|
| [whatsappChat](whatsappChat/) | Connects WhatsApp to the DMS chat system as a linked device |
| [chatRunner](chatRunner/) | Every conversation, from every chat provider, in one launcher list |
| [nixSearch](nixSearch/) | Search nixpkgs from the launcher |
| [systemPanel](systemPanel/) | Fullscreen system panel: logins, boot health, SSH, sudo, units, ports |

The two chat plugins are described below; the others have their own READMEs.

---

## The chat plugins

DMS has a chat system that knows nothing about any particular messaging service.
Providers arrive as plugins, and each ships a **bridge**: a small program that
translates its service into newline-delimited JSON. The DMS backend owns the
message store, unread counts, the attachment cache, notifications and search, so
a bridge only has to speak its protocol.

**whatsappChat** is one such provider. **chatRunner** is not a provider at all —
it is a launcher that lists whatever providers you have installed.

```
        chatRunner ──┐
                     ├──▶ DMS chat backend ◀── whatsappChat bridge ──▶ WhatsApp
        chat window ─┘         (store, notifications, search)
```

So chatRunner on its own shows an empty list. Install a provider first.

## Requirements

- A DMS build with chat support. Check with:

  ```sh
  dms chat providers
  ```

  If that reports an unknown command, your DMS predates the chat system.

- **Go**, but only for whatsappChat — its bridge is compiled for your machine
  rather than shipped as a binary. chatRunner is QML and needs nothing.

- **wl-clipboard** (`wl-copy`, `wl-paste`), for pasting attachments into the
  composer and copying them out.

## Install

Plugins live in `~/.config/DankMaterialShell/plugins/`. Symlinking from a clone
means `git pull` updates them in place, and the directory is watched, so they
appear without restarting the shell.

```sh
git clone git@github.com:by-architect/DMS-Plugins ~/src/dms-plugins
cd ~/src/dms-plugins

ln -s "$PWD/whatsappChat" ~/.config/DankMaterialShell/plugins/whatsappChat
ln -s "$PWD/chatRunner"   ~/.config/DankMaterialShell/plugins/chatRunner
```

### Build the WhatsApp bridge

```sh
cd ~/src/dms-plugins/whatsappChat
./build.sh
```

This has to be done once after installing and again after every update. The
plugin refuses to enable until the binary exists and says so, rather than
sitting silently at "disconnected".

### Turn them on

**WhatsApp** — Settings → Chats → enable **WhatsApp**. A QR code appears in its
container; scan it with your phone under *Settings → Linked devices → Link a
device*. First sync pulls your conversation history and may take a few minutes.

**Chat Runner** — Settings → Plugins → enable **Chat Runner**.

Removing a symlink uninstalls the plugin.

## Using them

Open the chat window, or one conversation on its own:

```sh
dms ipc call chats toggle                  # the full window, with the chat list
dms ipc call chats popout "Ada"            # one conversation, by name
dms ipc call chats popout "+905551234567"  # or by number
dms ipc call chats cycle                   # walk unread conversations
```

Worth binding under Settings → Keyboard Shortcuts.

In the launcher, type `c ` then a name, a number or an address. Every provider
appears in one list, and each row says which service it belongs to — so two
people with the same name, or the same person on two services, are told apart by
reading the row:

```
Ada Lovelace     WhatsApp  ·  2 unread  ·  +905551234567
Katherine        WhatsApp  ·  no messages yet
```

Selecting a row opens that conversation on its own.

### In a conversation

The text field always holds focus, so typing always goes there.

| | |
|---|---|
| `Enter` | Send |
| `Alt+K` / `Alt+J` | Move the selection through messages |
| `Shift+Enter` | Open the selected message's attachment or link |
| `Ctrl+Shift+C` | Copy the selected message, or its attachment as a file |
| `Alt+R` / `Alt+F` | Reply / forward |
| `Delete` | Delete for you, after confirming |
| `Shift+Delete` | Delete for everyone, after confirming |
| `Ctrl+V` | Attach an image or file from the clipboard |
| `Esc` | Close |

The help icon in the conversation header lists these too.

Attachments are pasted rather than browsed for: copy a file in a file manager,
or an image from a screenshot tool, and paste. A pasted or typed path followed
by a space is attached as well. Everything staged shows as a thumbnail above the
text field, so you can drop one before sending.

## Keeping the list manageable

A WhatsApp account is mostly not conversations — statuses, channels, broadcast
lists and archived chats crowd out the rest. Each provider declares what its
conversations are, and **Settings → Chats → WhatsApp → Chat filters** turns each
category on or off for the conversation list and the runner.

Hiding is only hiding: searching still finds them, and nothing is deleted.

Notifications are separate, and per provider: on or off, previews, groups,
archived, do not disturb, and one toggle per category so a service's statuses can
be silent without silencing the service.

## Where your data lives

| What | Where | Owner |
|---|---|---|
| WhatsApp session — the linked device itself | `~/.local/share/dms-whatsapp/session.db`, mode 0600 | whatsappChat |
| Messages and conversations | `~/.local/share/DankMaterialShell/chat/history.db` | DMS |
| Cached attachments | `~/.cache/DankMaterialShell/chat/media/` | DMS |
| Plugin settings | `~/.config/DankMaterialShell/plugin_settings.json` | DMS |

**The session database is your WhatsApp account.** Anyone who can read it can
read your messages. Keep it out of dotfile repos and shared backups.

To unlink, use *Sign out* in Settings → Chats, or remove the device from your
phone. Deleting the file locally leaves the device still linked on WhatsApp's
side.

## When something is wrong

```sh
dms chat providers              # what DMS found, and each one's state
dms chat status whatsappChat    # connection state, capabilities, restarts, stderr
dms chat tail whatsappChat      # live protocol traffic in both directions
```

`tail` is the useful one: a bridge runs as a child of the daemon, so without it
its output is invisible.

| Symptom | Usually |
|---|---|
| Plugin will not enable | The bridge is not built — run `./build.sh` |
| Stuck at "disconnected" | Check `dms chat status` for the error |
| Runner lists nothing | No provider is enabled, or everything is filtered out |
| Searching a number finds nothing | Handles arrive when the bridge connects; reconnect once |
| No Chats section in Settings | DMS was built without chat support |

## A note on trust

These plugins run as your user, with your permissions, and whatsappChat holds
your WhatsApp session. So do all DMS plugins — there is no sandbox.

whatsappChat uses [whatsmeow](https://github.com/tulir/whatsmeow), the library
most third-party WhatsApp clients are built on. WhatsApp does not sanction
third-party clients, and accounts have been restricted for using them. It works,
and has for years, but the risk is yours to weigh.

## Writing your own provider

The contract is `docs/CHAT-PLUGINS.md` in the DankMaterialShell repository, and
`quickshell/PLUGINS/EchoChatExample/` there is a complete working bridge in about
300 lines. A bridge can be written in any language — it reads JSON lines on
stdin and writes them on stdout.
