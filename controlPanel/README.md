# Control Panel

A fullscreen, keyboard-driven quick-settings panel for Phoenix /
DankMaterialShell: WiFi, Bluetooth and speaker device lists, each with an
on/off toggle right on the container, plus a fourth container of simple
toggles — Mic, Tailscale, Keep Awake, and any configured VPN profiles.

## Layout

```
┌──────────────────────────┬──────────────────────────┐
│ [W] WiFi          ● ⊙   │ [B] Bluetooth      ● ⊙   │
│   network 1              │   device 1                │
│   network 2               │   device 2                │
├──────────────────────────┼──────────────────────────┤
│ [S] Speaker        ● ⊙   │ Other                     │
│   output 1                │  [M] Microphone      ⊙   │
│   output 2                │  [T] Tailscale       ⊙   │
│                            │  [K] Keep Awake      ⊙   │
│                            │  VPN profile 1        ⊙   │
└──────────────────────────┴──────────────────────────┘
              [   / to search — "wifi home"   ]
```

Nothing here collapses or expands — every container is always fully visible
and independently scrollable. The letter badge on each toggle is a
vimium-style hint: it's not a section you open, it's the key that flips that
exact toggle, from anywhere in the panel, without touching the mouse.

## Keyboard model

Two-mode, vim/less-style, same as `wallpaperSearch` and `notificationPanel`:
the search bar is where you type; every other key is a direct action, and the
two never collide.

| Key | Effect |
|---|---|
| `W` | toggle the WiFi radio |
| `B` | toggle Bluetooth |
| `S` | toggle Speaker mute |
| `M` | toggle Microphone mute |
| `T` | toggle Tailscale |
| `K` | toggle Keep Awake (idle inhibit) |
| `/` | focus the search bar |
| `Esc` (search focused) | unfocus the search bar, back to panel mode |
| `Esc` (panel mode) | close the panel |
| `Enter` (search focused) | connect to the top result, then hand focus back to panel mode |
| `Ctrl+w` / `Ctrl+u` (search focused) | delete word before cursor / clear field |

The six single-letter toggles only fire in panel mode — the moment the
search field has focus, every keystroke goes to it as text, so typing
"wifi" doesn't also toggle WiFi via its `w`.

VPN profiles don't get a reserved letter: there can be zero, one, or several
of them, so each row is click-only rather than claiming a key that might not
mean the same thing next time you open the panel.

## Search / quick connect

Typing a command prefix followed by a query filters just that list —
`wifi home`, `bt sony`, `bluetooth sony`, `speaker headphones`,
`audio headphones`, `output headphones`, or the single-letter forms `w`/`b`/`s`
— and Enter connects to the top (first) result. Text with no recognized
prefix filters all three lists at once, generically.

Connecting: WiFi calls `NetworkService.connectToWifi(ssid)` with no password,
so it works for open networks and anything NetworkManager already has saved
credentials for — this is a quick-connect surface, not a credentials flow.

## Install

The plugin is not installed automatically. Symlink `controlPanel` into
`~/.config/DankMaterialShell/plugins/` and enable it:

```sh
ln -sfn "$PWD/controlPanel" ~/.config/DankMaterialShell/plugins/controlPanel
dms ipc call plugin-scan scan
dms ipc call plugins enable controlPanel
```

Then add the **Control Panel** widget to the bar under Settings → DankBar, or
bind the IPC call below to a key.

## Usage

```sh
dms ipc call controlPanel toggle   # also: open, close, status
```

`status` reports `keyboard=ready`/`not-focused` and `search=focused`/`unfocused`.
Unlike `notificationPanel`, this panel does **not** auto-focus the search bar
on open — the primary interaction here is the letter toggles, which only work
in panel mode, so opening straight into panel mode (not search mode) is the
right default.

## Implementation notes

Same non-obvious rules as the other panels in this repo (see `systemPanel`'s
README for the fullest detail): a `PanelWindow` declared inline inside a
`PluginComponent` never becomes a layer surface — it has to come from a
`LazyLoader`, kept permanently active so the Tailscale subscription and
everything else persists across opens; on Hyprland the shell ignores
layer-shell exclusive keyboard focus in favour of `hyprland_focus_grab`, so
the window mirrors the shell's own `KeyboardFocus` policy plus
`DankFocusGrab`; `exclusionMode: ExclusionMode.Ignore` +
`WlrLayershell.exclusiveZone: -1` make it draw over the bar instead of
reserving space below it; and `DankTextField`'s own root is a plain
`Rectangle`, not a `FocusScope`, so `field.activeFocus` never reflects the
inner `TextInput`'s real focus — `SearchBar.hasFocus`, forwarded through
`DankTextField`'s own `focusStateChanged(bool)` signal, is what actually
works.

**Keep Awake** is `SessionService.idleInhibited` /
`SessionService.toggleIdleInhibit()` — the same mechanism behind the `dms
ipc call inhibit` target and the shell's own idle-inhibit indicator, called
with no duration so it stays on until toggled off rather than expiring.

**Mic and Speaker toggle mute, not device power** — there's no single
physical "radio" to disable for audio the way there is for WiFi/Bluetooth, so
their on/off state is `!audio.muted` on the current default sink/source; the
Speaker container's device list still lets you switch which sink is default,
independent of the mute toggle.
