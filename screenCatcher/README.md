# Screen Catcher

A DankMaterialShell plugin for screenshots and screen recording, driven from a
centered keyboard-first panel rather than a bar dropdown. Open it with a
shortcut, hit a letter, done. A small bar icon shows recording status and
gives you a stop button, but it's not where the actions live.

```
                 ┌──────────────────────────────────────────┐
                 │  Screen Catcher              Esc closes ⨯│
                 │                                            │
                 │  Screenshot          │  Audio               │
                 │   [S] Selected        │   [M] Microphone  ○  │
                 │   [F] Fullscreen      │   [Y] System Audio ○ │
                 │   [T] To Text         │  Record              │
                 │                       │   [R] Fullscreen     │
                 │                       │   [D] Selected       │
                 │                       │   [G] Selected (GIF) │
                 └──────────────────────────────────────────┘
        (half the screen's width and height, centered, dimmed backdrop)
```

## Packages used

| Tool | For | Required? |
|---|---|---|
| `grim` | screenshots | required |
| `slurp` | region selection | required |
| `wf-recorder` | screen recording | required |
| `ffmpeg` | GIF conversion (palette-based) | optional — GIF falls back to raw mp4 |
| `tesseract` | OCR for Screenshot to Text | optional — that one action fails gracefully |
| `wl-clipboard` (`wl-copy`) | copying screenshots/text/GIFs | optional — skips clipboard copy |
| `notify-send` (libnotify) | desktop notifications | optional — skips notifications |
| `jq` | parsing `pw-dump` JSON | needed only for mic+system-audio mixing |
| `pw-dump`, `pw-loopback` (PipeWire) | default audio device lookup + mic/system-audio mixing | needed only for audio capture |

No PulseAudio/`pactl` — the audio device lookup and the mic+system-audio mix
(a `pw-loopback` sink plus two taps feeding into it) both use native PipeWire
tooling instead, since a PipeWire-only system may not have the PulseAudio
client installed. `wf-recorder` itself still connects over the pulse protocol
(via `pipewire-pulse`) for actual capture, so device names — including the
`<sink>.monitor` convention — are the same regardless of which tool found
them.

## Install

Symlink the `screenCatcher` directory itself (not its parent) into the DMS
plugin directory, then rescan:

```sh
ln -s "$PWD/screenCatcher" ~/.config/DankMaterialShell/plugins/screenCatcher
```

If the `dms` CLI isn't on your PATH, trigger the rescan straight through the
running quickshell instance instead:

```sh
SHELL_PATH=$(quickshell list --all | grep -oE '/[^ ]*/shell\.qml' | head -1)
quickshell -p "$SHELL_PATH" ipc call plugin-scan scan
```

Then enable **Screen Catcher** under Settings → Plugins. The bar icon is
optional (Settings → Appearance → DankBar Layout, if you want the recording
status readout); the panel works over IPC/keybinds with or without it.

## Opening the panel

The panel isn't a bar dropdown — it's a centered, half-screen overlay,
opened however you like:

```sh
quickshell -p <shell-path> ipc call screenCatcher toggle   # also: open, close, status
```

To bind this to a real keyboard shortcut: **Settings → Keybinds → Add →
Spawn**, and paste the command above (swap `toggle` for whichever action —
see the table below). This goes through DMS's own keybind manager, so no
compositor config editing needed.

## Letter shortcuts

Once the panel is open, press a letter — no need to click:

| Key | Action | Notes |
|---|---|---|
| `S` | Screenshot Selected | |
| `F` | Screenshot Fullscreen | |
| `T` | Screenshot to Text (OCR) | |
| `M` | Toggle Microphone | doesn't close the panel |
| `Y` | Toggle System Audio | doesn't close the panel |
| `R` | Record Fullscreen | only while not already recording |
| `D` | Record Selected | only while not already recording |
| `G` | Record Selected as GIF | only while not already recording |
| `X` | Stop Recording | only while recording |
| `Esc` | Close panel | recording (if any) keeps running in the background |

Every letter has a visible badge next to its row/toggle, so it's discoverable
without memorizing this table. Clicking works identically to pressing the
letter.

Screenshot/record actions close the panel first and wait ~180ms before
capturing, so the panel itself never ends up in the screenshot or recording.
Clicking outside the card (on the dimmed backdrop) also closes it.

## Every action has its own shortcut command

All of these work independently of the panel being open — bind any subset of
them directly under **Settings → Keybinds → Add → Spawn**:

```sh
quickshell -p <shell-path> ipc call screenCatcher <action>
```

| `<action>` | Effect |
|---|---|
| `open` / `close` / `toggle` | Show/hide the panel |
| `status` | Reports panel open/closed + recording state (for scripting) |
| `shotSelected` | Screenshot Selected — works even with the panel closed |
| `shotFullscreen` | Screenshot Fullscreen |
| `shotText` | Screenshot to Text |
| `recordFullscreen` | Start Record Fullscreen |
| `recordSelected` | Start Record Selected |
| `recordGif` | Start Record Selected as GIF |
| `micToggle` | Toggle microphone capture on/off |
| `sysAudioToggle` | Toggle system-audio capture on/off |
| `stop` | **The stop command** — stops whatever recording is running, or no-ops if nothing is |

`stop` is the one worth binding on its own: it's a global "kill whatever's
recording" hotkey that doesn't require the panel to be open at all.

## Stopping a recording

Any of these, all equivalent:

- Press `X` in the panel.
- Click the inline stop button in the bar pill (if you added it), whether or
  not the panel is open.
- `quickshell -p <shell-path> ipc call screenCatcher stop`, e.g. bound to its
  own shortcut.

Stopping sends `SIGINT` to `wf-recorder` (via the wrapper script), which lets
it finalize the output file properly rather than leaving a corrupt video.

## How it works

All the actual work — `grim`, `slurp`, `wf-recorder`, `ffmpeg`, `tesseract`,
PipeWire audio orchestration (`pw-dump`, `pw-loopback`) — lives in
`bin/screen-catcher.sh`, not in QML. `ScreenCatcherService.qml` (a singleton)
starts it as a `Quickshell.Io.Process` and, for recordings, keeps a handle to
it so it can call `.signal(2)` (SIGINT) to stop gracefully. The script
reports progress back over stdout (`STARTED <path>`, `SAVED <path>`,
`CANCELLED`, ...), which the singleton parses line-by-line to drive the UI —
being a singleton means the panel, the bar pill, and every IPC call all read
and drive the exact same recording state.

The plugin is a **composite** (`daemon` + `widget`):

- `ScreenCatcherDaemon.qml` — instantiated once. Owns the panel's open/closed
  state (`PluginGlobalVar`) and the `screenCatcher` IPC target with every
  action above.
- `ScreenCatcherPanelWindow.qml` — the actual layer-shell surface, created by
  a `LazyLoader` only while open (a `PanelWindow` declared inline never
  becomes a real layer surface). Fullscreen + dimmed backdrop for Esc/letter
  capture and click-outside-to-close, with a centered card sized to half the
  window's width/height for the actual content.
- `ScreenCatcherBarWidget.qml` — optional bar pill, status-only (no dropdown
  of its own): idle icon, or a red dot + elapsed timer + stop button while
  recording. Clicking it opens the panel.

Screenshot/OCR calls are one-shot (`Proc.runCommand`); only the recording
process needs to stay alive and be signaled, so it's the one long-lived
`Process` in the plugin.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Screenshot folder | `~/Pictures/Screenshots` | |
| Recording folder | `~/Videos/Recordings` | |
| Copy to clipboard | on | Screenshots, OCR text, and finished GIFs |
| Desktop notifications | on | One per finished action |
| OCR language | `eng` | Tesseract language code |
| GIF frame rate | 12 fps | |
| GIF width | 480 px | Height scales to match |
| Microphone device | auto | PipeWire/Pulse source name override |
| System audio device | auto | PipeWire/Pulse monitor source name override |

Mic/System Audio on-off state lives in the panel itself (not the settings
page), since it's something you're likely to flip per-recording.

## Requirements

`grim`, `slurp`, and `wf-recorder` are required (checked by a startup check
before the plugin activates). See the packages table above for the full list
and what degrades gracefully vs. what's load-bearing.
