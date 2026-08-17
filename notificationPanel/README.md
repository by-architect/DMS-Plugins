# Notification Panel

A fullscreen notification browser for Phoenix / DankMaterialShell: a live flow
of every notification on the right, six user-defined filtered categories on
the left, and a search bar that narrows all of them at once.

## Layout

```
┌───────────────────┬───────────────────┬──────────────┐
│  category 1        │  category 2        │              │
├───────────────────┼───────────────────┤    Flow      │
│  category 3        │  category 4        │  (every      │
├───────────────────┼───────────────────┤ notification, │
│  category 5        │  category 6        │  newest      │
│                    │                    │  first)       │
└───────────────────┴───────────────────┴──────────────┘
              [        search…        ]
```

The right column always shows every notification, newest first, narrowed only
by the search bar. Each of the six left tiles is empty until you assign it a
filter; a filled tile shows its own scrollable flow of just the notifications
that match, further narrowed by the same search bar.

## Filter syntax

Two different filter inputs exist, for two different situations.

**Categories** get a small rule builder, not a text field: each category is a
list of conditions, all of which must match (AND). Every condition picks a
**field** (Any field, Title, Content, App, Urgency), a **mode** (Include /
Exact match / Exclude), and a text value — e.g. field `App`, mode `Include`,
text `whatsapp`. "Add condition" appends another row; the live match count
under the rows updates as you type, before you save.

**The search bar** stays free text, for quick one-off narrowing on top of
whatever categories are already filtering. Whitespace-separated tokens are
ANDed together:

| Token | Matches |
|---|---|
| `whatsapp` | bare term — title, body, or app name |
| `title:whatsapp` | title/summary only |
| `app:signal` | app name only |
| `body:"good morning"` | quoted phrase, any field with spaces |
| `urgency:critical` | `low`, `normal`, or `critical` |
| `-app:spotify` | negation — excludes a match |

A category's conditions and the search bar combine with AND: a category
matching app `whatsapp` with `meeting` typed in the search bar shows only
WhatsApp notifications that also mention "meeting".

## Data source

Everything is read from `NotificationService.historyList` — the same
persisted, capped list (`SettingsData.notificationHistoryMaxCount`, default 50)
the shipped Notification Center's History tab renders from. It survives shell
restarts and needs no polling: the panel is a pure binding over that list, so
new notifications appear the instant they arrive.

Deleting a card (the × on hover) calls `NotificationService.removeFromHistory(id)`
— the same call the shipped history view uses — so it also disappears from
every other view of the same list.

**Not covered:** invoking a live notification's action buttons (reply, open
app, etc.) requires the transient `Notification` object from
`NotificationService.notifications`/`allWrappers`, which disappears once the
sender's connection closes. This panel is a browse-and-filter surface over the
persisted history, not a replacement for the popup/action flow — pair it with
the shipped Notification Center if you need to act on a still-live
notification.

## Categories

Stored under the plugin id via `PluginService.savePluginData` — an array of 6
slots, each `null` or `{ name, conditions: [{ field, mode, value }, ...] }`.
Click an empty tile to add one; the pencil/trash icons on a filled tile edit
or remove it. Editing happens inline, in the tile itself, and the whole form
scrolls if a category ends up with more conditions than fit.

Categories saved before this rule builder existed (a single free-text
`filter` string) still load and still match exactly what they matched before
— `migrateCategory()` in `filters.js` wraps the old string into one `Any
field / Include` condition the first time the panel starts.

## Install

The plugin is not installed automatically. Symlink `notificationPanel` into
`~/.config/DankMaterialShell/plugins/` and enable it:

```sh
ln -sfn "$PWD/notificationPanel" ~/.config/DankMaterialShell/plugins/notificationPanel
SHELL_PATH=$(quickshell list --all | grep -A1 "^Instance" | grep "Config path:" | head -1 | sed 's/.*Config path: //')
quickshell -p "$SHELL_PATH" ipc call plugin-scan scan
quickshell -p "$SHELL_PATH" ipc call plugins enable notificationPanel
```

Then add the **Notification Panel** widget to the bar under Settings → DankBar
— its pill shows a live count badge — or bind the IPC call below to a key.

## Usage

```sh
quickshell -p <shell-path> ipc call notificationPanel toggle   # also: open, close, status
```

`status` reports whether the panel holds keyboard focus (`keyboard=ready`),
useful when debugging compositor focus behaviour.

The search bar takes keyboard focus automatically on open, so typing starts
filtering immediately. **Esc** closes from anywhere, including while typing;
**q** also closes, but only when the search field isn't focused (otherwise
it'd just be typed as a search character).

## Implementation notes

This plugin follows the same two non-obvious rules as `systemPanel` (see its
README for the detail): a `PanelWindow` declared inline inside a
`PluginComponent` never becomes a layer surface — it has to come from a
`LazyLoader` — and on Hyprland the shell ignores layer-shell exclusive
keyboard focus in favour of `hyprland_focus_grab`, so the window mirrors the
shell's own `KeyboardFocus` policy plus `DankFocusGrab` rather than hardcoding
`WlrKeyboardFocus.Exclusive`.

Unlike `systemPanel`, there are no background processes here at all —
`NotificationService.historyList` is a live QML property, so every tile is
just a filtered/sorted binding over it. No timers, no polling.

`exclusionMode: ExclusionMode.Ignore` + `WlrLayershell.exclusiveZone: -1` make
the panel a true fullscreen overlay that draws over the bar, rather than
reserving space below it.

The window's `LazyLoader` stays **permanently active** — unlike the usual
plugin pattern of tying `active` to the open/closed state. With up to 50
history rows rendered across the flow and category tiles (each pulling an
icon through `DankCircularImage`), destroying and rebuilding that tree on
every open was the actual cause of the panel feeling slow to appear. Now the
daemon loads it once and the window's own `open` property just maps/unmaps
the surface; reopening is instant. The tradeoff is that the tree — and its
image cache — stays resident in memory for as long as the plugin is enabled,
not just while the panel is visible.
