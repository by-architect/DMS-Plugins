# Matrix Bar

A second bar, on the left edge, for every machine in matrix: how busy each
one is, how full its disks are, who is connected to it, and whether its
Syncthing, rsync pairs and backups are doing anything. It looks like DankBar
because it is drawn from DankBar's own settings, but it is its own bar — so
it can put two things side by side, which DankBar's single column of plugin
pills cannot.

![The bar: nebuchadnezzar, logos and mjolnir](docs/bar.png)

One block per machine, this one first:

```
   ╭──────╮
   │  ▭   │   the machine: a laptop, desktop or phone icon and three
   │ NEB  │   letters of its name, underlined when it is this machine
   │ ‾‾‾  │
   │ ▌  ▌ │   CPU | GPU                  bars filling from the bottom,
   │ 30 12│                              the percentage under each
   │ ▌  ▌ │   memory | swap
   │ 20 50│
   │ █  █ │   disk 1 | disk 2            "/" (a phone's internal storage)
   │ 77 40│                              first, then the biggest
   │ ▄  ▄ │   removable disks            two to a row, as many as there are
   │ 55 12│
   │  ▆▆  │   battery, when it has one   a bolt while it charges
   │  64  │
   │ ◢  ≋ │   a phone: signal | network  Wi-Fi with its strength, the mobile
   │ ✆ (8)│   a phone: calls | data used data kind (LTE, 5G…), or crossed out
   │ (4)  │   ssh connections to it now
   │ (✓)  │   Syncthing: ✓ idle, ⟳ working, ‖ paused
   │ (0)  │   rsync pairs running now
   │ (0)  │   backups running now
   ╰──────╯
```

Hover anything for what it is and the numbers behind it — used and total,
which folders are syncing, which pair failed, who is connected and from
where. Click a machine's name to fold it down to just its name; right-click
anywhere in its block to connect to it again.

```sh
dms ipc call matrixBar toggle            # show or hide the bar (also: show, hide)
dms ipc call matrixBar status            # one line per machine, tab separated
dms ipc call matrixBar refresh           # look for machines again, reconnect all
dms ipc call matrixBar reconnect logos   # one machine
```

## Where the machines come from

**matrix's own list.** The installed `matrix` command carries the devices file
it fans out to — every machine of the flake that is not public — and the bar
reads that same file, so a machine added to the flake is on the bar after the
next rebuild, and one removed is gone. `MATRIX_DEVICES_JSON_OVERRIDE` is
honoured the way matrix honours it, and the settings can name another file.

Public hosts (osiris) are left out, as matrix leaves them out.

The machine the shell runs on is in that list too; it is read directly
instead of over ssh, put first, and underlined.

## What each part shows

| | |
|---|---|
| CPU | busy share between two snapshots, from `/proc/stat` |
| GPU | the busiest GPU: NVIDIA from `nvidia-smi`, AMD from `gpu_busy_percent`, a phone's Adreno or Mali from its kernel. Intel (i915) from the time each program kept each engine busy, in `/proc/<pid>/fdinfo` — what `intel_gpu_top` shows, without root. Time out of RC6 sleep is only the fallback: a screen redrawn 120 times a second keeps an idle Intel GPU half awake |
| Memory | `MemTotal − MemAvailable` — what programs hold, not the page cache |
| Swap | used share, `–` without swap |
| Disks | the machine's own filesystems, one per device, `/` first then by size; tmpfs, overlay, network mounts and a `/boot` with room left out (the same rules as Host Status). More than two are listed in disk 2's tooltip |
| Removable | filesystems on a disk that can be pulled out: the kernel's removable flag, or a USB or SD card bus — never the disk `/` is on. A phone's SD card or USB drive |
| Battery | the machine's own battery (a mouse's is left out); amber at 30%, red at 15% |
| ssh | logged-in ssh connections to the machine now — sshd's `user@pts` and `user@notty` sessions — less the bar's own. ssh-link's standing connections from the other machines count: they are connections. The tooltip says from which machine |
| Syncthing | `working` while a folder scans or syncs, `paused` when `matrix sync pause` left its file or every folder or device is paused (syncthing-guard pauses them all on mobile data), `idle` otherwise, `stopped` on a folder error, a crossed circle when it does not run. Files that failed to sync turn the tick amber |
| rsync | sync-backup-manager's sync pairs running now (a oneshot unit while it is `activating`), plus any other rsync: one run by hand (its progress from fct, as a filling ring), or the far end of another machine's pair. Red when a pair failed last time, amber while one waits to retry |
| Backups | sync-backup-manager's borg backups, and restic, the same way |

Bars turn amber and red at 60% / 80% for CPU and GPU, 75% / 90% for memory
and disks, 50% / 80% for swap.

### A phone

Read over ssh as well — the same way matrix reaches it (Nixup's sshd, then
`su`) — and nearly all of it needs root, so the whole loop runs in one `su`:

| | |
|---|---|
| Signal | the bars Android shows for the SIM that is in service, from `dumpsys telephony.registry` |
| Network | one icon: Wi-Fi with its strength, the mobile data kind (LTE, 5G, H+…) when that carries the traffic, crossed out when neither does. Decided by where the default route leaves (`wlan*` or a modem), the same test syncthing-guard makes |
| Calls | the phone icon rings while a call comes in and fills during one; a red count of missed calls not yet looked at |
| Data used | Android's own mobile data counter for this cycle — the number Settings → Network → Data usage shows — as a ring, out of the phone's data limit, else its warning, else the allowance set here. Without any of them the ring shows the gigabytes |
| Disks | internal storage (`/data`) and each SD card or USB drive. Android mounts shared storage per app, so these are sized in init's view of the mounts, through `/proc/1/root` |

## How it reads

**One stream per machine.** Each machine runs `scripts/probe.sh` in a loop —
this one locally, the others over one ssh that stays open — and sends a
snapshot every 5 seconds (a phone every 15). The slow parts come every
30 seconds on a computer and every minute on a phone: storage, Syncthing,
missed calls; the phone's data counter every five minutes. Nothing has to be
installed on the machines: the probe is ssh's stdin, run by `sh -s`.

**Light on mobile data.** A phone, and a laptop on its hotspot, pay for every
line, so only what the bar reads is sent: the fields it uses out of
Syncthing's answers and Android's dumps rather than the whole of them, the
mount table's lines for the filesystems df listed, the data counter summed
per day, and the sync-backup-manager units and a phone's signal and Wi-Fi
only when they changed. A snapshot is about 250 bytes; one with the slow parts
a few kilobytes.

An open stream costs no new login: ssh rides the ControlMaster ssh-link keeps
open to each machine, and only falls back to a connection of its own when
there is none. ssh runs with:

```
-T -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1
-o ServerAliveInterval=15 -o ServerAliveCountMax=3
-o StrictHostKeyChecking=accept-new -o ControlMaster=no -o LogLevel=ERROR
```

A stream that ends is opened again — after 3 seconds when it had been
working, then after 10, 20, 40… seconds up to two minutes while it keeps
failing. One that goes quiet for three snapshots is stopped and opened again.
A machine that refuses the key or whose host key is unknown is not retried on
its own; right-click its block once it is fixed. While the bar is hidden no
machine is read at all.

## Settings

| | |
|---|---|
| Show the bar | the same as `dms ipc call matrixBar toggle` |
| Computers / phones: read every | seconds between snapshots (5 and 15) |
| Mobile data allowance | GB a month, for the data ring's percentage when the phone has no limit or warning set |
| Bar width | pixels; 0 follows DankBar's thickness, widened just enough for two bars and their numbers |
| Screen | one output's name; empty for every screen |
| Devices file | another machine list than matrix's |
| Machines on the bar | every machine is shown unless switched off here |

## Implementation notes

- The bar is a `PanelWindow` per screen, created by `Variants` in the daemon.
  Declared inline in the daemon it would never become a layer surface.
- It copies DankBar's look from the first enabled entry of
  `SettingsData.barConfigs`: thickness from `Theme.barThickness`, the gap to
  the screen edge, `barSurfaceColor` and `barTransparency`, the window radius
  (square while a window is maximized, as DankBar does), the widget pill fill,
  and the level-2 elevation shadow. It reserves only the bar band, not the
  shadow's room.
- Tooltips are a `PopupWindow` beside the bar: the bar's own window is too
  narrow to hold DMS's in-window tooltip.
- Nothing tells DMS's own surfaces that the left edge is taken: notification
  popups set to a left corner, or a dock on the left, would overlap the bar.
- The service is a singleton, and a singleton stays in the engine when a
  plugin is reloaded: after changing the plugin, restart DMS
  (`dms restart`, or `scripts/run-plugin-live.sh`) to load the new code.
- fct's wrappers stand in front of `curl` on these machines; the probe sets
  `FCT_DISABLE` so asking Syncthing's API is not logged as a download.
- `df -l` keeps network mounts out: a dead sshfs mount makes a plain `df`
  hang.
- On the phone, Syncthing runs in a mount namespace of its own with its API
  on a unix socket only root can open; the probe reaches both through
  `/proc/<syncthing pid>/root`.

## Tests

```sh
qmltestrunner -input tests/tst_bar.qml
```

`bar.js` holds everything that turns a snapshot into numbers — CPU and GPU
rates, disks, Syncthing's state, the jobs, the phone — and is tested against
snapshots shaped on real runs of the probe on a laptop, a desktop and a phone.
`scripts/test-plugin-all.sh` in the project runs it with the rest.
