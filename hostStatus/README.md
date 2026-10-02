# Host Status

Every host from [SSH Hosts](../sshManager/) in the bar: which ones answer, and
how busy each one is — CPU, memory, swap and disks — checked over ssh on a
timer. Nothing to install on the hosts themselves.

```
   bar:   [ ⛁ 4/4 ]      every host answered
          [ ⛁ 3/4 ]      amber: one is down     (red when none answer)

   click:
        ┌──────────────────────────────────────────────────────────┐
        │  Hosts                                               ⟳   │
        │  3 of 4 online · checked 12 s ago                        │
        │                                                          │
        │  (⛁)  mjolnir                           online   [>_]    │
        │       roland@100.70.50.1                                 │
        │       CPU     ███░░░░░░░░░░░░░░░░░░░             14%     │
        │       Memory  ████████████░░░░░░░░░░       9.3 / 15 GB   │
        │       Swap    ░░░░░░░░░░░░░░░░░░░░░░              none   │
        │       /       ███████████░░░░░░░░░░░       488 / 920 GB  │
        │       /boot   █░░░░░░░░░░░░░░░░░░░░░        74 / 1022 MB │
        │       checked 12 s ago · up 3d 4h · load 0.52 0.58 0.59  │
        │                                                          │
        │  (☁)  backup                       unreachable   [>_]    │
        │       neo@10.0.0.9:2222                                  │
        │       timed out                                          │
        │       checked 12 s ago · last online 2 h ago             │
        └──────────────────────────────────────────────────────────┘
```

`[>_]` opens an ssh session to the host — through SSH Hosts' own connect
action, so in the terminal configured there, exactly as `ssh <name>` in the
launcher would. Right-click the pill to check every host now.

## Where the hosts come from

**SSH Hosts' list, live.** Nothing is copied into this plugin: the hosts are
read off SSH Hosts' daemon (or its settings, while the daemon is not up), so
adding, editing or removing a host there shows up here at once. A host whose
address, port, user or key changed is checked again straight away.

This plugin's settings only hold which hosts to *leave out* — every host is
watched by default, including ones added later.

## What a row shows

| | |
|---|---|
| State | `online`, `unreachable`, `auth failed`, `host key not trusted`, `not checked` (a password host it cannot log in to), or a spinner while checking |
| CPU | busy share over one second, from two `/proc/stat` samples |
| Memory | used / total, where used is `MemTotal − MemAvailable` — what programs hold, not the page cache |
| Swap | used / total, or `none` |
| Storage | one bar per real filesystem, `/` first: tmpfs, overlay, squashfs, efivarfs and the other kernel mounts are left out, so are network mounts (they belong to the machine serving them), and a filesystem mounted twice (a bind mount, btrfs subvolumes) is shown once. Six at most; `dms ipc call hostStatus status` lists all |
| Footer | when it was checked, uptime, load average, CPU count — or when it was last seen online |

Bars turn amber past 75% and red past 90%.

## How it checks

One ssh per host per round, four hosts at a time, every 60 seconds by default —
and only while the pill is on a bar. Each ssh runs with:

```
-T -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1
-o ServerAliveInterval=5 -o ServerAliveCountMax=2
-o ControlMaster=no -o LogLevel=ERROR
```

plus the port, identity file and user from SSH Hosts. `BatchMode` means it never
prompts; `ControlMaster=no` uses a multiplexed connection you already have
open but never leaves a new one behind. A check that has not answered in 25
seconds is stopped and the host counts as unreachable.

The remote side is [`scripts/remote.sh`](scripts/remote.sh), sent as ssh's
stdin and run by `sh -s` on the far end — so it works whatever the login shell
is, and nothing is copied to the host. It prints raw `hs:`-prefixed lines
(`/proc/stat` twice, a second apart; `/proc/meminfo`; `/proc/uptime`;
`/proc/loadavg`; `/proc/mounts`; `df -P -k`), and all the arithmetic happens
here, in `hosts.js`. Lines without the prefix — a `.bashrc` that echoes
something — are ignored. `df` gets `timeout 5` where available, because one
dead NFS mount makes it hang forever.

**A host that refuses us is not retried on the timer.** `auth failed` and
`host key not trusted` stay as they are until you press refresh, or change
the host in SSH Hosts: a failing login every minute is exactly what fail2ban
bans for.

**A host key it has never seen is not accepted.** The check uses your
`ssh_config` as it is, and with the default `StrictHostKeyChecking ask` a new
host shows `host key not trusted` — open a session once with `[>_]`, accept
the key, and refresh.

## What the far end needs

A POSIX `sh` and `/proc` — that is, Linux, including busybox systems. Nothing to
install. On a machine without `/proc` (a BSD, macOS) the host is still shown
as online with its storage, and CPU and memory say `unknown`. A host whose
account cannot run commands at all (`nologin`, a forced command) shows as
online with `connected, but no stats`.

## Password hosts

Key auth is what this is built for. A host set to password auth in SSH Hosts
is only checked when:

1. a password is **stored** for it in SSH Hosts, and
2. **`sshpass`** is installed on this machine.

Otherwise its row says `needs key auth or sshpass` and it is not contacted at
all — not even a failed login attempt.

When it is checked, the password is handed to `sshpass -e` through the
`SSHPASS` environment variable of that one process — never on a command line,
where every user on the machine could read it in `ps`. It is asked of SSH Hosts
for each check and never written anywhere by this plugin. That ssh runs with
`BatchMode=no` and `NumberOfPasswordPrompts=1`, so a wrong password fails at
once instead of being typed three times, and it is not tried again until you
refresh (see above).

The trust boundary is SSH Hosts' own: its stored passwords are plaintext,
readable by your user account and handed to any plugin that asks — see
[its README](../sshManager/README.md#where-your-data-lives). Prefer keys.

## Seeing what it sees

The probe is a plain script; run it by hand against any host:

```sh
ssh user@host sh -s < scripts/remote.sh
sh scripts/remote.sh            # or on this machine
```

From the running shell, once the widget is on a bar (the service is a QML
singleton, so `Target not found` means it is enabled but not placed anywhere):

```sh
dms ipc call hostStatus status    # one tab-separated line per host
dms ipc call hostStatus refresh   # check every host now, refused ones too
```

## Settings

| Setting | Default | |
|---|---|---|
| Check every | 60 s | 15 s – 15 min |
| Show storage | on | the per-filesystem bars |
| Hosts to watch | all | one switch per SSH Hosts host |

## Installing

```sh
ln -sfn "$PWD/hostStatus" ~/.config/DankMaterialShell/plugins/hostStatus
dms ipc call plugin-scan scan
```

Enable **Host Status** under **Settings → Plugins**, then add it to a section
under **Settings → Bar**. It needs [SSH Hosts](../sshManager/) enabled to have
any hosts to show.

## Needs

`ssh` (OpenSSH's client) — a startup check makes sure it is on `PATH`.
`sshpass` only for password hosts.

## Shape

`hosts.js` holds the parsing, the filesystem filter, what each ssh failure is
called, and the text, as pure functions — tested by `tests/tst_hosts.qml`
(`qmltestrunner -input tests/tst_hosts.qml`; on NixOS add `-import <qtdeclarative>/lib/qt-6/qml`) against real probe output.

`HostStatusService` is a singleton, so the pill on every screen and the popout
share one set of results. Each check is its own `Process`, destroyed as soon
as its exit code and both output streams are in; one watchdog timer stops
checks past their deadline.
