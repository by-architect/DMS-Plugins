# Process Widget

How busy the CPU is, as one number in the bar — the number that matters most
right now, with an icon that says which one it is — and, one click away, what
is keeping it busy, with a button to end it.

```
   bar:   [ ▣ 7% ]        quiet: the whole machine
          [ ▣ 64% ]       the whole machine past its warning level (amber, red past critical)
          [ ▥ 97% ]       one core too busy
          [ >_ 120% ]     one process too busy (100% = one whole core)
           ▔▔▔▔▔▔         a hairline under the number: the whole machine's usage

   click:
        ┌──────────────────────────────────────────────────────┐
        │  CPU                                                 │
        │  22 cores · load 4.45 · 5.03 · 9.28                  │
        │                                                      │
        │  >_ cc1 is using 120% of a core                      │
        │                                                      │
        │   64%          ╱╲__╱╲___╱‾‾╲__╱‾                     │
        │   CPU in use                                         │
        │   Memory                     11.0 GiB of 15.1 GiB    │
        │   ██████████████████████████████████░░░░░░░░░░░░░    │
        │   Swap                       15.1 GiB of 16.6 GiB    │
        │   ███████████████████████████████████████████░░░░    │
        │                                                      │
        │   Per core                     busiest: cpu7  81%    │
        │   ▂▅▁▇▃▁▂█▁▃▂▁▄▁▂▁▃▁▆▂▁▂                             │
        │                                                      │
        │   Top processes                     CPU     MEM      │
        │   cc1                            120.0%    0.4%   ✕  │
        │   2574676 · cc1 -quiet -O2 foo.c                     │
        │   ghostty                          9.3%    0.8%   ✕  │
        │   2003957 · ghostty -e tmux attach-session -t main   │
        └──────────────────────────────────────────────────────┘
```

## What the pill shows

One number, picked in this order:

| Icon | When | The number |
|---|---|---|
| `terminal` | one process uses more than the **process alert** (90% of a core by default) | that process's share of one core, so a process busy on two cores reads 200% |
| `view_week` | otherwise, one core is busier than the **core alert** (90%) | that core's usage |
| `memory` | otherwise — and whenever nothing is past an alert | the whole machine's usage |

A process or core alert has to hold for **two samples in a row** to take over
the pill, and two quiet samples to give it back, so a page loading or a core
spiking for a moment does not flip it back and forth. It is amber, and red when
the whole machine is also past its critical level; the whole machine's number
keeps its own warning and critical colours. The popout names the process or
core in a line at the top, with the same icon.

## The number

The share of time the CPU was not idle between two readings of `/proc/stat`,
taken every two seconds. Idle means `idle` plus `iowait` — waiting on a disk is
not work — and `guest` time is left out of the total because the kernel already
counts it inside `user`. It agrees with `vmstat`'s `100 − id − wa` over the
same second.

The first reading after the shell starts only primes the counters, so the
second follows half a second later instead of a whole interval: the pill says
`--%` for a moment, never a since-boot average dressed up as "now".

Reading the file costs no process at all — Quickshell's `FileView` reads
`/proc/stat`, `/proc/meminfo` and `/proc/loadavg` directly.

## The popout

| | |
|---|---|
| The total | big, with its last 60 readings (two minutes at the default interval) as a graph |
| Memory | in use is `MemTotal − MemAvailable`, the figure `free` calls used — the page cache is not counted against you; swap underneath when there is any |
| Per core | one bar per core from the same `/proc/stat` read; hover a bar for its number, otherwise the busiest core is named |
| Load | the 1, 5 and 15 minute averages, in the header next to the core count to read them against |
| Processes | the busiest right now, one line each: the name, then the PID and the command with its program's path cut to the program (the owner too, when it is not you) |

**%CPU in the list is what each process used over the last sample**, as a share
of one core — what `top` shows, not `ps`'s average since the process started.
It comes from the process sampler (below); `ps -o pid=,user=,pmem=,args= ww -p …`
then fills in the owner, memory and command line for just the busiest few, and
only while the popout is actually on screen — DMS keeps a closed popout loaded
for a fast re-open, so the popout counts itself by its own visibility, not by
existing.

Every line in a row stays one line: DMS's text wraps by default, and a long
command line wrapping inside a fixed-height row is what once made the rows run
into each other.

Clicking a row copies its PID.

## The process sampler

To know what a process is using now, two readings of its CPU time are needed.
One `awk` reads every `/proc/PID/stat` (and `/proc/uptime`) in one go and prints
four numbers a process; two of those a couple of seconds apart give each
process's share of a core over exactly that interval. A process that started in
between counts all its time; a PID whose start time changed is a new process
that reused the number; the sampler leaves itself out. It costs about 10 ms of
CPU per run, in its own process, at most every two seconds.

## Killing

**✕** asks the process to exit (SIGTERM), which lets it save and close — and
lets it refuse. **Right-click ✕** forces it (SIGKILL). Before either signal,
the same rules as processRunner:

- **The PID is checked again first.** `ps -p PID -o args= ww` right before the
  signal; if nothing has that PID any more, nothing is sent ("Already gone"),
  and if it now belongs to a different command line — the listed process
  exited and its number was handed on — nothing is sent either ("Not killed").
- **Quickshell is refused outright**, by its own PID or by `quickshell`
  anywhere in the command line. Ending the desktop from its own bar is the one
  mistake worth actively preventing; its row's button is switched off.
- **Only real PIDs.** Digits only and above 1: `kill 0` would signal the whole
  process group and `kill -1` every process you own.

The signal is sent by the shell's own `kill` (`sh -c 'kill -s "$1" "$2"'`), so
no standalone `kill` binary is needed; the PID and the signal arrive as
arguments, never as part of the script. What `kill` says when it fails is what
the toast says.

Anything else your account may kill is yours to kill, the same as from a
terminal. This never runs as root, so it cannot touch other users' processes.

## When it runs

Nothing at all until the widget is on a bar: the sampler is a singleton, and
each pill counts itself in and out. Then:

| | |
|---|---|
| A pill exists | three procfs reads per interval, no process; one `awk` over `/proc/*/stat` per interval, at least two seconds apart |
| The popout is open | the `awk` at most once a second, plus one `ps` for the busiest few |
| The popout closes | the `ps` stops |
| The last pill goes | everything stops, and the next start primes afresh |

Every command runs in a `Process` of its own that is destroyed as soon as its
run is over — or after a timeout, for a `ps` stuck on a process in
uninterruptible sleep — so none are left behind; `status` reports how many are
running, which is 0 between runs.

## Seeing what it sees

From the running shell, once the widget is actually on a bar — the service is a
QML singleton, so nothing exists to answer until a pill is instantiated, and
`Target not found` means the widget is enabled but not placed anywhere:

```sh
dms ipc call processWidget status    # what the pill shows and why, the busiest process now, cpu, load, memory, the last list
dms ipc call processWidget refresh
```

The arithmetic and the parsing — and the sampler script itself, taken out of
`ProcessWidgetService.qml` and run — on this machine's own `/proc` and `ps`:

```sh
node tests/procstat.test.js
```

## Settings

| Setting | Default | |
|---|---|---|
| Sample every | 2000 ms | how often `/proc/stat` is read; the process sampler follows it, at least two seconds apart (at most once a second while the popout is open) |
| Processes listed | 8 | how many of the busiest the popout shows |
| Warning at | 60% | the whole machine's number turns amber |
| Critical at | 85% | the whole machine's number turns red; set below the warning level, it counts as equal to it |
| Process alert at | 90% | one process past this (of one core) takes over the pill, with the terminal icon |
| Core alert at | 90% | one core past this takes over the pill, with the column icon, when no process is past its alert |
| Usage bar under the number | on | the hairline along the bottom of the pill |

## Installing

Symlinking is enough, but the plugins directory watcher does not notice a new
**symlink**, so the shell has to be told to look:

```sh
ln -sfn "$PWD/processWidget" ~/.config/DankMaterialShell/plugins/processWidget
dms ipc call plugin-scan scan
dms ipc call plugin-scan list | grep processWidget   # processWidget unloaded widget …
```

Then enable it under **Settings → Plugins** (which is what writes
`enabled: true`, so it survives a restart) and add it to a section under
**Settings → Bar**. Until it is placed on a bar, nothing of it is instantiated.

## Needs

`ps` (procps), `awk`, and Linux's `/proc`.

## Shape

`procstat.js` holds the arithmetic and the parsing — `/proc/stat` deltas,
meminfo, loadavg, the process sampler's deltas, what the pill shows, `ps` lines
and the kill verdict — as pure functions, so they run and are tested outside
quickshell. `ProcessWidgetService` is the singleton that samples, lists and
kills; `CommandWorker` runs one command at a time with
a timeout and destroys each `Process` when it is done. The pill
(`ProcessWidget.qml`), the popout and its rows are layout over the service.
