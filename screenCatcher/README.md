# Screen Catcher

A DankMaterialShell plugin for screenshots and screen recording, driven from a
centered keyboard-first panel rather than a bar dropdown. Open it with a
shortcut, hit a letter, done. A small bar icon shows recording status (with a
pulsing red dot) and, on a horizontal bar, an inline stop button — but it's
not where the actions live.

```
        ┌────────────────────────────────────────────────────────┐
        │  Screen Catcher                             Esc closes ⨯│
        │                                                          │
        │  Screenshot              │  Audio                        │
        │   [S] Selected           │   [M] Microphone           ○  │
        │   [F] Fullscreen         │   [Y] System Audio         ○  │
        │   [T] To Text            │  Record                       │
        │   [1] PNG   [2] JPEG     │   [R] Fullscreen              │
        │  Save screenshots        │   [D] Selected                │
        │   [C] Save to Clipboard ○│   [G] Selected as GIF         │
        │   [P] Save to Pictures  ○│   [3] MP4   [4] MKV           │
        │   [N] Notifications     ○│  Save recordings              │
        │                          │   [B] Save to Clipboard    ○  │
        │                          │   [V] Save to Videos       ○  │
        │                          │  (while recording:) [X] Stop  │
        └────────────────────────────────────────────────────────┘
        (half the screen's width and height, centered, dimmed backdrop)
```

## Packages used

| Tool | For | Required? |
|---|---|---|
| `grim` | screenshots | required |
| `slurp` | region selection | required |
| `wf-recorder` | screen recording | required |
| `ffmpeg` | GIF conversion | required for *Record Selected as GIF* only |
| `tesseract` | OCR for Screenshot to Text | optional — that one action fails gracefully |
| `wl-clipboard` (`wl-copy`) | copying screenshots/text/recordings to the clipboard | optional — skips clipboard copy |
| `notify-send` (libnotify) | desktop notifications | optional — skips notifications |
| `jq` | parsing `pw-dump`/`hyprctl` JSON | needed for mic+system-audio mixing and multi-monitor output detection |
| `pw-dump`, `pw-loopback` (PipeWire) | default audio device lookup + mic/system-audio mixing | needed only for audio capture |
| `hyprctl` (Hyprland) | detecting the focused monitor for fullscreen screenshots and recording | Hyprland only — see below |

No PulseAudio/`pactl` — the audio device lookup and the mic+system-audio mix
(a `pw-loopback` sink plus two taps feeding into it) both use native PipeWire
tooling instead, since a PipeWire-only system may not have the PulseAudio
client installed. `wf-recorder` itself still connects over the pulse protocol
(via `pipewire-pulse`) for actual capture, so device names — including the
`<sink>.monitor` convention — are the same regardless of which tool found
them.

**Multi-monitor "fullscreen" means the screen you are on**, for both
screenshots and recording. `grim` with no `-o` captures the whole compositor
layout — every monitor stitched into one image — which is not what fullscreen
means to anyone with a second screen, so the focused output is passed
explicitly.

**Multi-monitor fullscreen recording** needs to know which output to record.
`wf-recorder` prompts *interactively* for a choice when more than one output
exists and none is given, which just hangs forever with no terminal attached
— this was a real, confirmed bug ("record fullscreen not working"). Fixed by
detecting the focused output via `hyprctl monitors -j` (Hyprland) or
`niri msg --json focused-output` (Niri, best-effort — no Niri session was
available to test against) and passing it explicitly — the same lookup both
actions use. On neither compositor, it falls back to whatever `wf-recorder -L`
lists first rather than hanging (and screenshots fall back to grim's
capture-everything behaviour).
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
| `C` | Screenshots: toggle Save to Clipboard | doesn't close the panel |
| `P` | Screenshots: toggle Save to Pictures | doesn't close the panel |
| `N` | Toggle Desktop Notifications | doesn't close the panel |
| `M` | Toggle Microphone | doesn't close the panel |
| `Y` | Toggle System Audio | doesn't close the panel |
| `R` | Record Fullscreen | only while not already recording |
| `D` | Record Selected | only while not already recording |
| `G` | Record Selected as GIF | only while not already recording |
| `3` / `4` | Record format: MP4 / MKV | only while not already recording |
| `B` | Recordings: toggle Save to Clipboard | doesn't close the panel |
| `V` | Recordings: toggle Save to Videos | doesn't close the panel |
| `X` | Stop Recording | also cancels one still waiting on a selection |
| `Esc` | Close panel | recording (if any) keeps running in the background |

Every letter has a visible badge next to its row/toggle/chip, so it's
discoverable without memorizing this table. Clicking works identically to
pressing the key.

**Where captures go** is two independent choices per kind, because wanting a
screenshot on the clipboard is routine while wanting a whole video on it is
not (and the reverse for keeping files):

| | Clipboard | Keep the file |
|---|---|---|
| Screenshots + OCR text | `C` (on by default) | `P` → the screenshot folder (on by default) |
| Recordings (mp4/mkv/gif) | `B` (off by default) | `V` → the recording folder (on by default) |

With "keep the file" off, the capture is written to a scratch directory,
put on the clipboard, and the scratch directory is deleted — nothing is left
behind on disk. Turning *both* off for the same kind would mean capturing into
the void, so the file is kept in that case; silently discarding what you just
captured is never the helpful reading of two toggles being off.

**GIF is its own action** (`G`, Record Selected as GIF), not a format chip. A
GIF chip left selected quietly turns the next ordinary recording into a GIF,
which is exactly the kind of surprise a mode you have to remember to switch
back off produces. MP4 and MKV record natively (wf-recorder muxes straight to
whichever extension it's given); GIF records to mp4 first and gets
palette-converted afterwards, since wf-recorder has no real-time GIF encoder
worth using. Screenshots get the same chip treatment with PNG/JPEG.

**GIF quality** defaults to 1920px wide at 20 fps, converted with a per-clip
256-colour palette built from the frames that actually change
(`palettegen=stats_mode=diff` + `paletteuse=dither=sierra2_4a`), scaled with
lanczos, and never upscaled past the source. Both the width and the frame rate
are settings. Be aware that a long full-width GIF takes real time to convert
and gets large fast — that is the trade for the quality.

**No pause/resume.** It was removed on request, and with it the
segment-splitting and ffmpeg concat pass that only existed because
`wf-recorder` has no pause of its own. A recording now runs as a single
`wf-recorder` process from start to stop.

Screenshot/record actions close the panel first and wait 350ms before
capturing, so the panel itself never ends up in the screenshot or recording.
Destroying the window is not the same as the compositor having repainted
without it — at the 100ms this used to wait, the panel was still in the
captured image. Clicking outside the card (on the dimmed backdrop) also
closes it.

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
| `recordSelectedGif` | Start Record Selected as GIF (ignores the format chip) |
| `stop` | **The stop command** — stops whatever recording is running (or cancels one still waiting on a selection), or no-ops if nothing is |
| `micToggle` | Toggle microphone capture on/off |
| `sysAudioToggle` | Toggle system-audio capture on/off |
| `clipboardToggle` | Screenshots: toggle Save to Clipboard |
| `picturesToggle` | Screenshots: toggle Save to Pictures (keep the file) |
| `videoClipboardToggle` | Recordings: toggle Save to Clipboard |
| `videosToggle` | Recordings: toggle Save to Videos (keep the file) |
| `notifyToggle` | Toggle desktop notifications on/off |
| `setImageFormat <png\|jpeg>` | Set the screenshot format, e.g. `ipc call screenCatcher setImageFormat jpeg` |
| `setRecordFormat <mp4\|mkv>` | Set the recording format (GIF is its own action, not a format) |

`stop` is the one worth binding on its own: it's a global "kill whatever's
recording" hotkey that doesn't require the panel to be open at all.

## Stopping a recording

Any of these, all equivalent:

- Press `X` in the panel. (The same row is there while a recording is still
  being set up, labelled *Cancel Recording*, so a selection you no longer want
  can be called off without leaving slurp on screen.)
- Click the inline stop button in the bar pill, on a horizontal bar. A
  *vertical* bar pill deliberately has no stop button: icon + timer + a round
  stop button stacked vertically came out taller than the bar's own thickness,
  so the pill grew past its slot and overlapped the widget above it. There,
  click the pill to open the panel and press `X`.
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
and, for recordings, keeps a handle to it so it can send `SIGTERM` to stop.
The script reports progress back over stdout (`STARTED <path>`,
`SAVED <path>`, `COPIED <name>`, `CANCELLED`, `TEXT <text>`, `EMPTY`), which
the singleton parses line-by-line to drive the UI — being a singleton means
the panel, the bar pill, and every IPC call all read and drive the exact same
recording state.

**Toasts report finished work, never work starting.** Nothing is shown when a
recording begins (the bar pill is already saying so, in place, for as long as
it runs); the toast comes when the file is actually finished — "Recording
saved", "GIF saved", "Screenshot copied to clipboard", and so on. For GIFs
that is deliberately *after* the palette conversion, not when `wf-recorder`
stops, so the toast never claims a file exists while ffmpeg is still writing
it.

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

**System audio needed a `pw-dump` shape fix.** The default sink/source lookup
piped the PipeWire `default` metadata through `jq`'s `fromjson`, but pw-dump
emits that metadata value as an already-decoded JSON *object*, not as a JSON
string — so jq failed with "only strings can be parsed", both lookups came
back empty, and turning System Audio on silently recorded video only (the
script's own "could not find the default output" notification is easy to miss
when notifications are off). Both shapes are handled now, and a recording made
with System Audio on was confirmed to come out with a real AAC audio stream in
it.

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
  of its own): idle icon, or a pulsing red dot + elapsed timer while
  recording, plus an inline stop button on horizontal bars only (see
  *Stopping a recording* for why the vertical pill has none). Clicking it
  opens the panel. On a vertical bar the pill's height *is* its inner
  padding, so it carries an explicit vertical pad and never sits shorter than
  the bar is thick — otherwise the icon ends up flush against the widgets
  above and below it.

Screenshot/OCR calls are one-shot (`Proc.runCommand`); only the recording
process needs to stay alive and be signaled, so it's the one long-lived
`Process` in the plugin.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Screenshot folder | `~/Pictures/Screenshots` | |
| Recording folder | `~/Videos/Recordings` | |
| Screenshots: copy to clipboard | on | Screenshots and OCR text. Also panel toggle `C` |
| Screenshots: keep the file | on | Off = clipboard only, no file left behind. Also panel toggle `P` |
| Recordings: copy to clipboard | off | mp4/mkv/gif onto the clipboard. Also panel toggle `B` |
| Recordings: keep the file | on | Off = clipboard only. Also panel toggle `V` |
| Desktop notifications | on | One per finished action. Also panel toggle `N` |
| Default screenshot format | PNG | Also panel chips `1`/`2` |
| Default recording format | MP4 | Also panel chips `3`/`4` |
| OCR language | `eng` | Tesseract language code |
| GIF frame rate | 20 fps | Applies to *Record Selected as GIF* |
| GIF width | 1920 px | Max width; height scales to match, never upscaled past the source |
| Microphone device | auto | PipeWire/Pulse source name override |
| System audio device | auto | PipeWire/Pulse monitor source name override |

Mic/System Audio on-off state lives in the panel only (not the settings
page), since it's something you're likely to flip per-recording. Everything
else in this table lives in both places.

## Requirements

`grim`, `slurp`, and `wf-recorder` are required (checked by a startup check
before the plugin activates). See the packages table above for the full list
and what degrades gracefully vs. what's load-bearing.
