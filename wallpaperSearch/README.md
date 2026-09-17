# Wallpaper Search

A fullscreen, keyboard-driven wallpaper browser for Phoenix / DankMaterialShell:
search Wallhaven or browse a local folder, in two tabs, and apply a result
without touching the mouse.

## Keyboard model

Same two-mode, vim/less-style model as `controlPanel`: the search bar is
where you type, everything else is a single keystroke away, and the two never
collide.

| Key | Effect |
|---|---|
| `/` | focus the search bar |
| `Esc` (search focused) | unfocus the search bar, back to panel mode |
| `Esc` (panel mode) | close the panel |
| `Enter` (search focused) | run the search, then hand focus back to panel mode |
| `Ctrl+h` / `Ctrl+l` | move selection left / right |
| `Ctrl+j` / `Ctrl+k` | move selection down / up |
| `Ctrl+Enter` | download and apply the selected **Wallhaven** result |
| `Alt+Enter` | apply the selected **Local** image directly (no download) |
| `Alt+j` / `Alt+k` | next / previous tab |
| `Ctrl+w` / `Ctrl+u` (search focused) | delete word before cursor / clear field |

`Ctrl`/`Alt`+`Enter` and `Alt+j/k` are live regardless of whether the search
field has focus, since those combos never type a character. Everything else
that's a bare letter is scoped to panel mode, so typing a query never
triggers a hotkey by accident.

## The two tabs

**Wallhaven** — SFW-only (`purity=100`), no API key needed or supported.
Typing a query and pressing Enter fetches the first page of results
(`https://wallhaven.cc/api/v1/search`); the API isn't queried on every
keystroke. The top result is pre-selected the moment results arrive, so
`Ctrl+Enter` alone (no navigation) grabs the top hit.

**Local** — scans the configured folder once per panel session (or on first
switch to the tab) for `.jpg`/`.jpeg`/`.png`/`.webp`/`.avif` files, up to 4
directories deep. Unlike Wallhaven, filtering here is live as you type — it's
just a substring match over already-known filenames, so there's no reason to
gate it behind Enter. Pressing Enter still works (hands focus back to the
panel, same as it does for Wallhaven) for a consistent "type, then navigate"
flow across both tabs.

## Applying a wallpaper

`Ctrl+Enter` (Wallhaven) downloads the selected image's full-resolution file
to the configured install location, then calls `SessionData.setWallpaper(path)`
— the same call the shipped Settings → Wallpaper tab uses, so matugen theme
regeneration and everything else downstream of a wallpaper change happens
exactly as it would from the normal UI. `Alt+Enter` (Local) skips the
download and calls it directly on the already-local file.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `localPath` | `~/Pictures/Wallpapers` | Folder the Local tab scans |
| `installLocation` | `~/Pictures/Wallpapers/wallhaven` | Where applied Wallhaven images are saved |

## Install

The plugin is not installed automatically. Symlink `wallpaperSearch` into
`~/.config/DankMaterialShell/plugins/` and enable it:

```sh
ln -sfn "$PWD/wallpaperSearch" ~/.config/DankMaterialShell/plugins/wallpaperSearch
SHELL_PATH=$(quickshell list --all | grep -A1 "^Instance" | grep "Config path:" | head -1 | sed 's/.*Config path: //')
quickshell -p "$SHELL_PATH" ipc call plugin-scan scan
quickshell -p "$SHELL_PATH" ipc call plugins enable wallpaperSearch
```

Then add the **Wallpaper Search** widget to the bar under Settings → DankBar,
or bind the IPC call below to a key.

## Usage

```sh
quickshell -p <shell-path> ipc call wallpaperSearch toggle   # also: open, close, status
```

`status` reports `keyboard=ready`/`not-focused` and `search=focused`/`unfocused`.

## Implementation notes

Same non-obvious rules as the other panels in this repo (see `systemPanel`'s
README for the fullest detail): a `PanelWindow` declared inline inside a
`PluginComponent` never becomes a layer surface — it has to come from a
`LazyLoader`; on Hyprland the shell ignores layer-shell exclusive keyboard
focus in favour of `hyprland_focus_grab`; the window's `LazyLoader` stays
permanently active so search results and the local scan persist across
opens instead of rebuilding from scratch; and `DankTextField`'s own root is a
plain `Rectangle`, not a `FocusScope`, so `field.activeFocus` never reflects
the inner `TextInput`'s real focus state — `SearchBar.hasFocus`, forwarded
through `DankTextField`'s own `focusStateChanged(bool)` signal, is what
actually works.

**A GridView's `currentIndex` binding breaks the first time anything assigns
to it directly** — standard QML binding-override behavior, but easy to trip
over here because there are two independent sources of truth that both want
to drive it (an external `win.wallhavenIndex`/`localIndex`, and clicking a
cell directly). Every selection change goes through `selectWallhaven()` /
`selectLocal()`, which update both the index property and `grid.currentIndex`
together, imperatively, every time — nothing else touches either directly.

The `Ctrl+Enter` download runs `mkdir -p` and `curl` as one shell command
rather than calling `Paths.mkdir()` (which is fire-and-forget
`execDetached`, with no way to know when — or whether — it finished) followed
by a separate download command; otherwise there's a real, if narrow, race on
the very first download to a not-yet-existing install directory.
