# Process Widget

How busy the CPU is, as one number in the bar — and, one click away, what is
keeping it busy, with a button to end it.

```
   bar:   [ ▣ 7% ]        quiet
          [ ▣ 64% ]       amber from the warning level up, red from the critical one
           ▔▔▔▔▔▔         a hairline under the number, as long as the CPU is busy

   click:
        ┌──────────────────────────────────────────────────────┐
        │  CPU                                                 │
        │  22 cores · load 4.45 · 5.03 · 9.28                  │
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
        │   dsearch                        168.0%    2.4%   ✕  │
        │   neo · 2574676 · /nix/store/…/dsearch serve         │
        │   java                            38.5%   15.2%   ✕  │
        │   neo · 2838773 · /home/neo/.mozbuild/jdk/…/java …   │
        └──────────────────────────────────────────────────────┘
```

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
| Processes | the busiest by CPU, from `ps -eo pid=,user=,pcpu=,pmem=,args= --sort=-pcpu ww` |

The process list is the one part that costs a `ps` run, so it runs only while
the popout is actually on screen — DMS keeps a closed popout loaded for a fast
re-open, so the popout counts itself by its own visibility, not by existing.

**%CPU in the list is `ps`'s figure:** the CPU time a process has used divided
by how long it has existed, per core — a busy multi-threaded process passes
100%. It is the same number `ps aux` and processRunner show, not `top`'s
per-interval one, so a process that has only just started spinning shows up
in the total at once and climbs the list gradually.

Clicking a row copies its PID.

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
| A pill exists | three procfs reads per interval, no process |
| The popout is open | plus one `ps` per interval (at most one a second) |
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
dms ipc call processWidget status    # cpu, load, memory, swap, the last process list
dms ipc call processWidget refresh
```

The arithmetic and the parsing, on this machine's own `/proc` and `ps`:

```sh
node tests/procstat.test.js
```

## Settings

| Setting | Default | |
|---|---|---|
| Sample every | 2000 ms | how often `/proc/stat` is read; the open popout's process list follows it, at most once a second |
| Processes listed | 8 | how many of the busiest the popout shows |
| Warning at | 60% | the pill turns amber |
| Critical at | 85% | the pill turns red; set below the warning level, it counts as equal to it |
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

`ps` (procps), and Linux's `/proc`.

## Shape

`procstat.js` holds the arithmetic and the parsing — `/proc/stat` deltas,
meminfo, loadavg, `ps` lines and the kill verdict — as pure functions, so they
run and are tested outside quickshell. `ProcessWidgetService` is the singleton
that samples, lists and kills; `CommandWorker` runs one command at a time with
a timeout and destroys each `Process` when it is done. The pill
(`ProcessWidget.qml`), the popout and its rows are layout over the service.
