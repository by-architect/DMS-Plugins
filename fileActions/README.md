# File Actions

A bar pill for long file operations, fed by a directory of status files: one
file per action, each holding that action's current JSON. Whatever writes those
files — a `cp` wrapper, a sync script, a downloader — shows up in the bar
without knowing anything about the shell.

The pill is the action that started most recently. Everything else is one click
away.

```
   bar:   [ ⧉ 94% ]                     ← newest running action, progress underneath
          [ ⧉ 94% +1 ]                  ← and one more running behind it

   click:
        ┌────────────────────────────────────────────────┐
        │  File Actions                               ⨯  │
        │  2 actions running                             │
        │                                                │
        │  (⧉)  .cache → newcache                  94%   │
        │       ████████████████████████████░░           │
        │       5.26 GB of 5.59 GB · 294,90MB/s · 18s …  │
        │       nvim-ts-autotag.luac                     │
        │                                                │
        │  (⇅)  photos → backup                    12%   │
        │       ███░░░░░░░░░░░░░░░░░░░░░░░░░░░           │
        │       1.1 GB of 9.4 GB · 41,2MB/s · 3m 20s …   │
        │                                                │
        │  Finished                                      │
        │  ✓  oldname → newname            2m ago        │
        │     mv · 1.18 MB · in 1m 4s                    │
        │  ✕  old                          6m ago        │
        │     rm failed · Permission denied              │
        └────────────────────────────────────────────────┘
```

## The directory

`$XDG_RUNTIME_DIR/matrix/dejavu` by default, changeable in settings. It does
not have to exist — the plugin says so instead of erroring, and picks the first
file up the moment one appears.

Every file in it is read as JSON on its own. One file being half-written costs
that one row for one poll (the previous reading stays on screen), not the whole
list.

## The file

One action, one file, rewritten in place as it progresses. The example this was
built against:

```json
{
  "id": "cp-406584",
  "pid": 406584,
  "command": "cp",
  "status": "running",
  "percent": 94,
  "bytes_done": 5645904734,
  "bytes_total": 6006281631,
  "rate": "294,90MB/s",
  "eta": "0:00:18",
  "current_file": ".cache/nvim/luac/%2fhome%2fneo%2f.local%2fshare%2fnvim%2flazy%2fnvim-ts-autotag%2flua%2fnvim-ts-autotag.luac",
  "source": "/home/neo/Downloads/.cache/",
  "target": "/home/neo/Downloads/newcache",
  "started": "2026-09-23T19:33:43+03:00"
}
```

Every field is optional; a file with nothing but `command` and `status` still
gets a row. Alternate names are accepted for each, so an existing writer
usually needs no changes:

| Field | Also read as | Used for |
|---|---|---|
| `command` | `action`, `op` | the row's icon and the word in the finished list |
| `status` | `state` | running / finished / failed — see below |
| `percent` | `percentage`, `progress` | the bar and the pill; falls back to `bytes_done / bytes_total` |
| `bytes_done` | `done`, `transferred` | "5.26 GB of 5.59 GB" |
| `bytes_total` | `total`, `size` | as above, and the size in the finished list |
| `rate` | `speed` | shown verbatim, whatever units the writer uses |
| `eta` | `remaining` | `0:00:18`, `4:32` and plain seconds all become "18s", "4m 32s" |
| `source` | `src`, `from` | left half of "name → name" |
| `target` | `dest`, `destination`, `to` | right half |
| `current_file` | `current`, `file` | the dim third line, percent-decoded, basename only |
| `started` | `start`, `started_at`, `begin` | ordering, and "in 1m 4s" once finished |
| `finished` | `ended`, `completed`, `finished_at`, `end` | when it ended |
| `error` | `message`, `reason` | the red line under a failed action |
| `id`, `pid` | — | carried through; the file name is what identifies a row |

Timestamps may be ISO 8601 (`2026-09-23T19:33:43+03:00`) or epoch
seconds/milliseconds.

**Status** is matched loosely, because writers disagree about wording:
anything containing *fail*, *error*, *abort*, *cancel*, *denied* or *timeout*
is a failure; *done*, *complete*, *finish*, *success* or *ok* is finished;
*run*, *copy*, *sync*, *pend*, *queue*, *paus* and friends are still running,
and so is a word the plugin has never seen — an unrecognised status on a file
that still exists is much more likely to be a state nobody thought to document
than a finished action.

Delete the file when the action ends, or leave it there with a terminal
status; both work.

## What it does that a progress bar does not

**Stalled actions are called stalled.** Nothing in a status file says whether
the process writing it is still alive, so an action whose file has not changed
for 45 seconds (configurable) turns amber and says `stalled` where the
percentage was. A frozen `94%` is exactly what makes a dead copy look healthy.

**A file that disappears mid-run is reported as *ended*, not done.** Only a
file that was at 99.5% or more when it vanished is assumed to have succeeded —
that is the ordinary case of a writer cleaning up after itself. Anything else
gets an amber `ended`, with the percentage it stopped at.

**The finished list is memory only.** It is what just happened, and after a
shell restart nothing just happened. Right-click the pill, or use the sweep
button in the popout header, to clear it early.

## Settings

| Setting | Default | |
|---|---|---|
| Status directory | `$XDG_RUNTIME_DIR/matrix/dejavu` | where the files are |
| Hide when nothing is running | off | remove the pill from the bar entirely while idle |
| Refresh while active | 800 ms | how often the directory is re-read during an action |
| Refresh while idle | 3000 ms | how often it is checked for a new one |
| Stalled after | 45 s | unchanged-file threshold for the stalled flag |
| Finished actions kept | 20 | rows under the running ones |

## How it reads the directory

One `sh` pass per poll prints a marker, each file's name and each file's
contents; the parsing, the phase rules and the history merge all live in
`actions.js` as pure functions over the previous snapshot, so they can be run
and tested outside quickshell. The QML above it is layout.

There is one poller for the whole shell, not one per monitor:
`FileActionsService` is a singleton, and the bar pill on every screen plus the
popout all read the same two lists off it.
