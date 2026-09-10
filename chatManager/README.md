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
                                        ├── history.db     shared message store
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

A provider goes in `~/.config/DankMaterialShell/chat-providers/`, not in
`plugins/`. It has no QML and no surface the shell can draw, so stock DMS would
reject its manifest as invalid and say so on every scan. Keeping providers in
their own directory avoids that entirely.

The plugins directory is still read, so an existing install where providers were
symlinked in beside ordinary plugins keeps working.

## Building

```sh
./build.sh
```

Needs Go. CGO is off — the SQLite driver is pure Go — so the binary runs
anywhere.

## Resource cost

The manager only streams state while the window is open. Closing it unsubscribes,
so a shell sitting idle all day with chats closed does no work per arriving
message beyond what the bridge and the store already do.
