# Chats (chatManager)

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

The wire protocol is unchanged from when the host lived inside `dms`, which is
why **provider bridges needed no changes at all**.

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

## Building

```sh
./build.sh
```

Needs Go. CGO is off — the SQLite driver is pure Go — so the binary runs
anywhere.

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

The manager only streams state while the window is open. Closing it unsubscribes,
so a shell sitting idle all day with chats closed does no work per arriving
message beyond what the bridge and the store already do.
