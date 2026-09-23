# File Actions

A bar pill for long file operations, fed by the `fct` wrappers (`cp`, `mv`,
`rm`, `rsync`, `scp`, `curl`, `wget`, `aria2c`, `torrent`, `git-clone`,
`trash-*`) from [MatrixProject][matrix]. The pill is the action that started
most recently. Everything else is one click away.

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
        │  ✓  .cache → newcache            36m ago       │
        │     cp · 51216 files · 5.81 GB · in 22s        │
        │  ✕  .cache → newcache            37m ago       │
        │     cp failed · Copying .cache/ to newcache …  │
        └────────────────────────────────────────────────┘
```

[matrix]: ../../MatrixProject

## Two sources, because the wrappers have two outputs

This is the part worth knowing before changing anything here.

**Running** actions come from the live state directory —
`$XDG_RUNTIME_DIR/matrix/fct`, one JSON file per running operation, rewritten
about four times a second. `$XDG_RUNTIME_DIR/matrix/dejavu` is the same
directory under the name the tool had before it was renamed, and is used only
when `fct` is not there — an older generation is what booted. First one that
exists wins; one live directory is the whole truth.

**Finished** actions do *not* come from there. The wrapper deletes its state
file on every exit path — success, failure, or a Ctrl+C — so the directory can
only ever answer "what is running now". How something went is in the event log,
where each wrapper writes one record per operation:

1. `~/.local/state/fct.json` — one JSON record per line, preferred because it
   is a `tail` away and needs no journal access
2. `journalctl -t matrix-fct -t matrix-dejavu -o json` — the same fields as
   `MATRIX_*` on a journal entry, read only if neither state file is readable

Both shapes go through one parser, so the rows are identical either way.

A consequence worth stating: the finished list is there the first time the
popout is opened, even if nothing has run since the shell started, and it
survives a shell restart. Nothing about it is kept in the plugin.

## The live file

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

Written tmp+rename, so a half-written file is never observed — but each file is
parsed on its own anyway, so a reader that did catch one would lose that row
for one poll rather than the whole list.

Every field is optional and alternate names are accepted (`action`/`op` for
`command`, `progress` for `percent`, `dest`/`to` for `target`, `src`/`from` for
`source`, `speed` for `rate`, `remaining` for `eta`, `current`/`file` for
`current_file`), so a hand-rolled writer can feed this too. `rate` is shown
verbatim in whatever units it arrives in; `eta` accepts `0:00:18`, `4:32` or a
plain number of seconds and comes out as "18s", "4m 32s". Timestamps may be ISO
8601 or epoch seconds/milliseconds. `current_file` is percent-decoded and
reduced to its basename, because a cache path otherwise fills the row.

`status` is matched loosely: anything containing *fail*, *error*, *abort*,
*cancel*, *denied* or *timeout* is a failure, *done*, *complete*, *finish*,
*success* or *ok* is finished, and everything else — including a word this
plugin has never seen — is still running. The `fct` wrappers only ever write
`running` here, so this matters only for other writers.

## The event log record

```json
{"host":"nebuchadnezzar","date":"2026-09-23T19:34:05+03:00","service":"fct",
 "command":"cp","status":"success","name":".cache",
 "source":"/home/neo/Downloads/.cache/","target":"/home/neo/Downloads/newcache",
 "total":"51216","size":"5947.9","log":null,"epoch":"1790182445"}
```

`status` is `started`, `success` or `fail`. `total` is a **file count** and
`size` is **megabytes**, not bytes — both are already converted by the time
they are logged. `log` carries the plain-English failure sentence, which is
what the red line under a failed row says.

A run is identified by its command plus what it was pointed at, never by pid:
each record is written by its own short-lived process, so an action's `started`
and `success` never share one. Pairing them is what produces "in 22s".

## What it does that a progress bar does not

**Stalled actions are called stalled.** Nothing in a live file says whether the
process writing it is still alive, so an action whose file has not changed for
45 seconds (configurable) turns amber and says `stalled` where the percentage
was. A frozen `94%` is exactly what makes a dead copy look healthy.

**A vanished file is a stand-in row, not a verdict.** When a state file
disappears the plugin shows an amber `ended` row with the percentage it stopped
at — and drops it the moment the event log produces the real record for that
run, which is normally within one poll. If the log cannot be read at all, those
stand-ins are the whole finished list rather than nothing.

**Zeros are not shown.** `0,00kB/s · 0s left` is what the first second of a
transfer looks like before the writer has anything to report, and it reads as a
stall; the row shows what it knows and nothing else. An action reporting 0% with
no totals and no rate — a `git-clone` receiving objects, a copy in its first
moments — gets an indeterminate bar rather than a `0.0%` that claims a
measurement nobody made.

**"Clear finished" hides, it does not delete.** The event log is not this
plugin's to truncate, so the sweep button (and a right-click on the pill) means
"everything older than now is no longer interesting".

## When it looks idle and should not

The two readers are plain shell scripts, runnable by hand — they print what
they resolved before they print anything else:

```sh
sh scripts/live.sh          # base:, watch:, ok: … then every live status file
sh scripts/history.sh 20    # source:, then the last 20 event-log records
```

The same answer from the running shell, which is the one that matters, since
its environment is not your terminal's:

```sh
dms ipc call fileActions status
```

```
runtime base: /run/user/1000
watching:     /run/user/1000/matrix/fct  /run/user/1000/matrix/dejavu
present:      /run/user/1000/matrix/fct
history from: /home/neo/.local/state/fct.json
running:      0
finished:     20 rows
```

`dms ipc call fileActions refresh` re-reads both immediately.

Both scripts resolve `$XDG_RUNTIME_DIR` and `$HOME` themselves, falling back to
`/run/user/$(id -u)` and the passwd entry, because the shell that runs the bar
does not necessarily carry either — and a path guessed wrong in QML looks
exactly like "nothing is running". The popout's empty state prints the paths it
actually looked at for the same reason.

## Settings

| Setting | Default | |
|---|---|---|
| Status directory | `matrix/fct`, or `matrix/dejavu` if that is what exists | where live files are |
| Hide when nothing is running | off | remove the pill from the bar entirely while idle |
| Refresh while active | 800 ms | how often the directory is re-read during an action |
| Refresh while idle | 3000 ms | how often it is checked for a new one |
| Refresh finished list | 30000 ms | backstop only — the log is re-read the moment an action ends |
| Stalled after | 45 s | unchanged-file threshold for the stalled flag |
| Finished actions kept | 20 | rows under the running ones |

## Shape

`scripts/live.sh` and `scripts/history.sh` are the only things that touch the system;
`actions.js` holds the parsing, the phase rules, the started→finished pairing
and the history merge as pure functions over the previous snapshot, so they run
and are tested outside quickshell. The QML above them is layout.

There is one poller for the whole shell, not one per monitor:
`FileActionsService` is a singleton, and the bar pill on every screen plus the
popout all read the same two lists off it. The popout's rows are bound through
an index rather than modelled on the array itself, so a poll updates a row in
place instead of rebuilding it and restarting its progress animation.
