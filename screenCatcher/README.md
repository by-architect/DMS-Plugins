# Screen Catcher

A DankMaterialShell plugin for screenshots and screen recording, driven from a
centered keyboard-first panel rather than a bar dropdown. Open it with a
shortcut, hit a letter, done. A small bar icon shows recording status (with a
pulsing red dot) and gives you a stop button, but it's not where the actions
live.

```
                 ┌──────────────────────────────────────────┐
                 │  Screen Catcher              Esc closes ⨯│
                 │                                            │
                 │  Screenshot          │  Audio               │
                 │   [S] Selected        │   [M] Microphone  ○  │
                 │   [F] Fullscreen      │   [Y] System Audio ○ │
                 │   [T] To Text         │  Record              │
                 │   [1] PNG  [2] JPEG   │   [R] Fullscreen     │
                 │  Save                 │   [D] Selected       │
                 │   [C] Clipboard   ○   │   [3]MP4 [4]MKV [5]GIF│
                 │   [L] Downloads   ○   │  (while recording:)  │
                 │   [N] Notifications ○ │   [P] Pause/Resume   │
                 │                       │   [X] Stop           │
                 └──────────────────────────────────────────┘
        (half the screen's width and height, centered, dimmed backdrop)
```

## Packages used

| Tool | For | Required? |
|---|---|---|
| `grim` | screenshots | required |
| `slurp` | region selection | required |
| `wf-recorder` | screen recording | required |
| `ffmpeg` | GIF conversion, joining paused segments | optional — degrades gracefully (see below) |
| `tesseract` | OCR for Screenshot to Text | optional — that one action fails gracefully |
| `wl-clipboard` (`wl-copy`) | copying screenshots/text/GIFs | optional — skips clipboard copy |
| `notify-send` (libnotify) | desktop notifications | optional — skips notifications |
| `jq` | parsing `pw-dump`/`hyprctl` JSON | needed for mic+system-audio mixing and multi-monitor output detection |
| `pw-dump`, `pw-loopback` (PipeWire) | default audio device lookup + mic/system-audio mixing | needed only for audio capture |
| `hyprctl` (Hyprland) | detecting the focused monitor for fullscreen recording | Hyprland only — see below |
| `xdg-user-dir` | resolving a localized/custom Downloads folder | optional — falls back to `~/Downloads` |

No PulseAudio/`pactl` — the audio device lookup and the mic+system-audio mix
(a `pw-loopback` sink plus two taps feeding into it) both use native PipeWire
tooling instead, since a PipeWire-only system may not have the PulseAudio
client installed. `wf-recorder` itself still connects over the pulse protocol
(via `pipewire-pulse`) for actual capture, so device names — including the
`<sink>.monitor` convention — are the same regardless of which tool found
them.

**Multi-monitor fullscreen recording** needs to know which output to record.
`wf-recorder` prompts *interactively* for a choice when more than one output
exists and none is given, which just hangs forever with no terminal attached
— this was a real, confirmed bug ("record fullscreen not working"). Fixed by
detecting the focused output via `hyprctl monitors -j` (Hyprland) or
`niri msg --json focused-output` (Niri, best-effort — no Niri session was
available to test against) and passing it explicitly. On neither compositor,
it falls back to whatever `wf-recorder -L` lists first rather than hanging.
Single-monitor systems are unaffected either way. "Record Selected" was never
affected, since `wf-recorder` derives the output from the selected region.

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

Once the panel is open, press a letter or number — no need to click:

| Key | Action | Notes |
|---|---|---|
| `S` | Screenshot Selected | |
| `F` | Screenshot Fullscreen | |
| `T` | Screenshot to Text (OCR) | |
| `1` / `2` | Image format: PNG / JPEG | doesn't close the panel |
| `C` | Toggle Save to Clipboard | doesn't close the panel |
| `L` | Toggle Save to Downloads | doesn't close the panel |
| `N` | Toggle Desktop Notifications | doesn't close the panel |
| `M` | Toggle Microphone | doesn't close the panel |
| `Y` | Toggle System Audio | doesn't close the panel |
| `R` | Record Fullscreen | only while not already recording |
| `D` | Record Selected | only while not already recording |
| `3` / `4` / `5` | Record format: MP4 / MKV / GIF | only while not already recording |
| `P` | Pause / Resume Recording | only while recording — same key both ways |
| `X` | Stop Recording | only while recording |
| `Esc` | Close panel | recording (if any) keeps running in the background |

Every letter has a visible badge next to its row/toggle/chip, so it's
discoverable without memorizing this table. Clicking works identically to
pressing the key.

**Save to Clipboard** and **Save to Downloads** both apply to every
screenshot and recording — Downloads is an *additional* copy alongside the
configured Screenshot/Recording folder, not a replacement for it. Both are
also available as persisted settings, so you can set a default without
opening the panel.

**Format chips** replace what used to be a separate "Record Selected as GIF"
action — GIF is now just one of three format choices (MP4/MKV/GIF) that apply
to *either* Record Fullscreen or Record Selected. MP4 and MKV record natively
(wf-recorder muxes straight to whichever extension you give it); GIF records
normally and gets palette-converted afterward, since wf-recorder has no
real-time GIF encoder worth using. Screenshots get the same treatment with
PNG/JPEG.

Screenshot/record actions close the panel first and wait ~100ms before
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
| `status` | Reports panel open/closed + recording state (`idle`, `starting`, `recording:<mode>:<elapsed>`) |
| `shotSelected` | Screenshot Selected — works even with the panel closed |
| `shotFullscreen` | Screenshot Fullscreen |
| `shotText` | Screenshot to Text |
| `recordFullscreen` | Start Record Fullscreen (uses the current format chip) |
| `recordSelected` | Start Record Selected (uses the current format chip) |
| `pause` | Pause the running recording |
| `resume` | Resume a paused recording |
| `stop` | **The stop command** — stops whatever recording is running (or cancels one still waiting on a selection), or no-ops if nothing is |
| `micToggle` | Toggle microphone capture on/off |
| `sysAudioToggle` | Toggle system-audio capture on/off |
| `clipboardToggle` | Toggle Save to Clipboard on/off |
| `downloadsToggle` | Toggle Save to Downloads on/off |
| `notifyToggle` | Toggle desktop notifications on/off |
| `setImageFormat <png\|jpeg>` | Set the screenshot format, e.g. `ipc call screenCatcher setImageFormat jpeg` |
| `setRecordFormat <mp4\|mkv\|gif>` | Set the recording format |

`stop` is the one worth binding on its own: it's a global "kill whatever's
recording" hotkey that doesn't require the panel to be open at all.

## Pausing a recording

`wf-recorder` has no pause/resume of its own — confirmed by testing: sending
it a second signal just terminates it the same way stopping does. Pause/resume
is implemented in the wrapper script instead: pausing stops `wf-recorder` and
finalizes that "segment"; resuming starts a fresh segment continuing from
where you left off. When the recording is finally stopped, every segment gets
joined into one file with `ffmpeg`'s concat demuxer (a lossless stream copy,
since all segments share identical encoder settings — no quality loss, and
fast since nothing gets re-encoded). Without `ffmpeg`, pause/resume still
works, but only the last segment is kept if you paused (a notification says
so) — install `ffmpeg` for gapless multi-segment recordings.

## Stopping a recording

Any of these, all equivalent:

- Press `X` in the panel. (The same row is there while a recording is still
  being set up, labelled *Cancel Recording*, so a selection you no longer want
  can be called off without leaving slurp on screen.)
- Click the inline stop button in the bar pill (if you added it), whether or
  not the panel is open.
- `quickshell -p <shell-path> ipc call screenCatcher stop`, e.g. bound to its
  own shortcut.

Stopping sends `SIGTERM` to the wrapper script (not `SIGINT` — see below),
which lets it finalize the output file properly rather than leaving a corrupt
video.

## How it works

All the actual work — `grim`, `slurp`, `wf-recorder`, `ffmpeg`, `tesseract`,
PipeWire audio orchestration (`pw-dump`, `pw-loopback`), output detection
(`hyprctl`) — lives in `bin/screen-catcher.sh`, not in QML.
`ScreenCatcherService.qml` (a singleton) starts it as a `Quickshell.Io.Process`
and, for recordings, keeps a handle to it so it can send signals: `SIGTERM` to
stop, `SIGUSR1` to pause, `SIGUSR2` to resume. The script reports progress
back over stdout (`STARTED <path>`, `PAUSED`, `RESUMED`, `SAVED <path>`,
`CANCELLED`, ...), which the singleton parses line-by-line to drive the UI —
being a singleton means the panel, the bar pill, and every IPC call all read
and drive the exact same recording state.

**Why `SIGTERM` and not `SIGINT` for stopping**: confirmed by testing that a
script invoked as a backgrounded async job can end up with `SIGINT` and
`SIGQUIT` permanently ignored for its entire lifetime (a documented bash
behavior — signals ignored on entry to a non-interactive shell can't be
trapped or reset), while an identical `trap ... TERM` in the same script fired
correctly every time. Rather than gamble on whether Quickshell's own process
spawning happens to avoid that inherited-ignore case, the plugin uses `TERM`
throughout, which was also confirmed to make `wf-recorder` itself finalize
cleanly.

**Screenshot/OCR calls disable the default timeout.** The shared `Proc`
helper this plugin (and the rest of DMS) uses for one-shot commands has a
10-second default timeout, meant for commands that should complete quickly.
`slurp` is interactive and human-paced — taking more than 10 seconds to
position a selection is completely normal, not a hang. With the default
timeout, this fired *while the user was still selecting*, killing the process
and reporting a bogus error a few seconds before the (still-shutting-down)
slurp surface actually disappeared — this was the "gives error, waits a lot,
then slurp opens" bug. Screenshot Selected and Screenshot to Text both pass
`Proc.noTimeout` now; Screenshot Fullscreen keeps the default since it never
touches slurp.

**`slurp` must be given a detached stdin.** Per `slurp(1)`, when stdin is not
a TTY, slurp first reads a list of predefined rectangles from it — and it only
maps its selection overlay once that read hits EOF. Quickshell hands a spawned
process a pipe that is never closed, so every slurp started from the shell sat
in `read()` forever: no overlay, no error, no exit, no notification. That is
the whole reason Screenshot Selected, Screenshot to Text and Record Selected
looked like they simply did nothing (confirmed: the stranded slurp processes
were parked in `anon_pipe_read` with no layer surface mapped, while the same
binary run from a terminal worked fine). The script does `exec </dev/null` up
front and runs slurp through `select_region()`, which redirects stdin again
and runs slurp in the background so a stop/cancel signal can take the overlay
down with it — an orphaned slurp keeps grabbing the pointer while being
effectively invisible.

**`StdioCollector.text` is read-only, and assigning to it killed recording.**
`startRecording()` used to clear the stderr collector (`recStderr.text = ""`)
one line before `recProcess.running = true`. That assignment throws
`TypeError: Cannot assign to read-only property "text"`, which aborts the rest
of the function — so the recording process was never started, for either mode,
while the IPC call still cheerfully returned `OK` and the only trace was a
`WARN` in the shell log. Worse, on the selection path the throw happened
*after* `isSelecting` had been set, and the old guard refused to start
anything while that flag was set, so one failed Record Selected silently
disabled every later recording for the rest of the session. The collector
resets itself when the next process stream starts, so nothing needed clearing
in the first place; `isSelecting` is now derived from the process rather than
assigned, which makes a stuck value impossible.

The plugin is a **composite** (`daemon` + `widget`):

- `ScreenCatcherDaemon.qml` — instantiated once. Owns the panel's open/closed
  state (`PluginGlobalVar`) and the `screenCatcher` IPC target with every
  action above.
- `ScreenCatcherPanelWindow.qml` — the actual layer-shell surface, created by
  a `LazyLoader` only while open (a `PanelWindow` declared inline never
  becomes a real layer surface). Fullscreen + dimmed backdrop for Esc/letter
  capture and click-outside-to-close, with a centered card sized to half the
  window's width/height for the actual content. The two-column split uses
  plain `Row`/`Column` with an explicit width formula rather than
  `QtQuick.Layouts` — `Layout.fillWidth` on a `Column` nested in a
  `RowLayout` produced a badly off-center divider (the `Column`'s own
  implicit-width-from-children computation fights the Layout's fill
  assignment).
- `ScreenCatcherBarWidget.qml` — optional bar pill, status-only (no dropdown
  of its own): idle icon, or a pulsing red dot + elapsed timer + stop button
  while recording (the icon switches to a static pause glyph, and the pulse
  stops, while paused). Clicking it opens the panel.

Screenshot/OCR calls are one-shot (`Proc.runCommand`); only the recording
process needs to stay alive and be signaled, so it's the one long-lived
`Process` in the plugin.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Screenshot folder | `~/Pictures/Screenshots` | |
| Recording folder | `~/Videos/Recordings` | |
| Copy to clipboard | on | Screenshots, OCR text, and recordings. Also panel toggle `C` |
| Save to Downloads | off | Extra copy into your Downloads folder. Also panel toggle `L` |
| Desktop notifications | on | One per finished action. Also panel toggle `N` |
| Default screenshot format | PNG | Also panel chips `1`/`2` |
| Default recording format | MP4 | Also panel chips `3`/`4`/`5` |
| OCR language | `eng` | Tesseract language code |
| GIF frame rate | 12 fps | Applies when the GIF format chip is selected |
| GIF width | 480 px | Height scales to match |
| Microphone device | auto | PipeWire/Pulse source name override |
| System audio device | auto | PipeWire/Pulse monitor source name override |

Mic/System Audio on-off state lives in the panel only (not the settings
page), since it's something you're likely to flip per-recording. Everything
else in this table lives in both places.

## Requirements

`grim`, `slurp`, and `wf-recorder` are required (checked by a startup check
before the plugin activates). See the packages table above for the full list
and what degrades gracefully vs. what's load-bearing.
