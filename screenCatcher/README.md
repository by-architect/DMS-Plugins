# Screen Catcher

A DankMaterialShell bar plugin for screenshots and screen recording. Click the
bar icon to open a two-column popup: screenshots on the left, audio toggles and
recording on the right.

```
┌───────────────────┬───────────────────┐
│ Screenshot         │ Audio              │
│  Screenshot Selected│  [ ] Microphone   │
│  Screenshot Fullscreen│ [ ] System Audio│
│  Screenshot to Text │ Record             │
│                    │  Record Fullscreen │
│                    │  Record Selected   │
│                    │  Record Selected as GIF │
└───────────────────┴───────────────────┘
```

While recording, the bar icon turns into a live status: a red dot, elapsed
time, and an inline stop button — no need to reopen the popup. The popup
itself also swaps its record actions for a big "Stop Recording" button while
one is running.

## Install

Symlink it into the DMS plugin directory and rescan:

```sh
ln -s "$PWD/plugins/screenCatcher" ~/.config/DankMaterialShell/plugins/screenCatcher
dms ipc call plugin-scan scan
```

Then enable **Screen Catcher** under Settings → Plugins and add it to your
DankBar.

## Features

- **Screenshot Selected** — drag a region (via `slurp`), saved as PNG and
  copied to the clipboard.
- **Screenshot Fullscreen** — captures the whole output.
- **Screenshot to Text** — select a region, OCR it with `tesseract`, and copy
  the recognized text to the clipboard.
- **Record Fullscreen / Record Selected** — `wf-recorder` to MP4, with
  optional microphone and/or system audio.
- **Record Selected as GIF** — same as Record Selected, but the finished
  recording is converted to an optimized GIF (palette-based, via `ffmpeg`) and
  copied to the clipboard.
- **Mic / System Audio toggles** — persisted on/off switches that apply to
  every recording started afterward. With both on, the plugin mixes them into
  one virtual source via `pw-loopback` (a bare loopback sink plus two taps
  feeding into it) so `wf-recorder`, which only accepts a single `-a` device,
  still captures both.

Every action closes the popup first and waits ~180ms before capturing, so the
popup itself never ends up in the screenshot or recording.

## Stopping a recording

Three ways, all equivalent:

- Click the stop icon inline in the bar pill while it's recording.
- Open the popup and click "Stop Recording".
- The bar pill's red dot + elapsed timer is always visible while recording, so
  you never lose track of an active capture.

Stopping sends `SIGINT` to `wf-recorder` (via the wrapper script), which lets
it finalize the output file properly rather than leaving a corrupt video.

## How it works

All the actual work — `grim`, `slurp`, `wf-recorder`, `ffmpeg`, `tesseract`,
PipeWire audio orchestration (`pw-dump`, `pw-loopback`) — lives in
`bin/screen-catcher.sh`, not in QML. QML
starts it as a `Quickshell.Io.Process`, and for recordings keeps a handle to
it so it can call `.signal(2)` (SIGINT) to stop gracefully. The script reports
progress back over stdout (`STARTED <path>`, `SAVED <path>`, `CANCELLED`,
...), which `ScreenCatcherService.qml` (a singleton, so all bar instances and
the popup share one recording state) parses line-by-line to drive the UI.

Screenshot/OCR calls are one-shots (`Proc.runCommand`); only the recording
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

Mic/System Audio on-off state lives in the popup itself (not the settings
page), since it's something you're likely to flip per-recording.

## Requirements

`grim`, `slurp`, and `wf-recorder` are required (checked by a startup check
before the plugin activates). Optional: `tesseract` for Screenshot to Text,
`ffmpeg` for GIF conversion, `wl-clipboard` for clipboard copy, and PipeWire's
own `pw-dump`/`pw-loopback` (plus `jq`) for audio device auto-detection and
mic+system-audio mixing — no PulseAudio/`pactl` install needed even on a
pure-PipeWire system. Missing optional tools degrade gracefully with a
notification rather than blocking the plugin.
