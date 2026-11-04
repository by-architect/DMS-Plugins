# Phone Status

Your Android phone in the bar, read over ssh. It shows what KDE Connect
shows about a phone, and more, from the phone's own system counters. That
includes **the mobile data used this cycle, by the same counter Android's
Settings reads**.

```
   bar:   [ ▂▄▆█  ▮ 57%  ③ ]     signal, battery, notifications waiting

   click:
        ┌──────────────────────────────────────────────────────────┐
        │  Logos                                    🔔  🔒  >_  ⟳  │
        │  M2007J20CG · Android 16 · checked 12 s ago              │
        │                                                          │
        │  ▮  Battery     57% · charging (USB) · 32.2 °C · 89% …   │
        │  ▆  Signal      Turkcell · LTE · excellent (-87 dBm)     │
        │  ⇅  Mobile data connected                                │
        │  ◌  Wi-Fi       off                                      │
        │  ⊚  Hotspot     on · 1 device                            │
        │  🔊 Sound       ring                                      │
        │  ▤  Storage     44.2 GB of 113 GB used                   │
        │                                                          │
        │  Mobile data                                             │
        │  46.3 GB  used since 26 Oct                              │
        │  ▁▂▁▃█▅▂▁▁▆▃                                             │
        │  today 1.19 GB · warning at 2.15 GB · new cycle 26 Nov   │
        │                                                          │
        │  ▶  Song — Singer · VLC                                   │
        │                                                          │
        │  2 notifications                                         │
        │  4m  Element  Ada — are you coming?                      │
        │  1h  Seraph manager  Backup finished — 2 apps backed up  │
        │  Show 4 ongoing (Termux, KDE Connect, ntfy, …)           │
        │                                                          │
        │  Newest photos                                           │
        │  [  ] [  ] [  ] [  ]                                     │
        └──────────────────────────────────────────────────────────┘
```

Right-click the pill to check now. The popout's buttons:

- **Ring**: the phone's ringtone at full media volume for 15 seconds, to find
  it. The volume goes back to what it was afterwards.
- **Lock**: turns the phone's screen off.
- **>_**: opens an ssh session through SSH Hosts.
- **Refresh**: checks the phone now.

Click a photo to open it.

## Why ssh, not KDE Connect

KDE Connect gets what the phone's app chooses to send. Over ssh, with root,
it is the system's own record: `dumpsys battery`, `telephony.registry`,
`netstats`, `notification` and `media_session`. Nothing is installed on the
phone besides Termux and its sshd, and nothing runs on it between checks.

## Setting up

1. On the phone, in Termux: `pkg install openssh`, put your key in
   `~/.ssh/authorized_keys`, and start `sshd`. It listens on port 8022 unless
   you changed it.
2. Allow Termux root, in Magisk or the ROM's root settings. Without root, only
   the battery shows.
3. Add the phone to **SSH Hosts** with key auth, and connect once from there
   to accept its host key.
4. Pick it under **Settings → Plugins → Phone Status → Phone**.
5. For **Ring**, also run `pkg install mpv` in Termux.

## Mobile data

The counter is Android's own: the **Xt** record that Settings → Network → Data
usage reads, from `dumpsys netstats --full`. The probe sums it on the phone
into one line per hour for the last 40 days. Like Settings, it counts metered
mobile networks only (`type=0`, `metered=true`). That includes what the
phone's hotspot carried. Both of Android's entries for that traffic are added
together: what the kernel saw, and what hardware tethering offload carried
past it.

The cycle, the warning and the limit come from the phone's data policy (`dumpsys
netpolicy`): its start day and time, monthly. A cycle starting on the 31st
starts on the last day in shorter months, as on the phone. With no data plan
set on the phone, the cycle is the calendar month, and the popout says so.

Android writes new traffic into the counter about every half hour. Opening the
popout asks it to do so first (`dumpsys netstats --poll`), so the number is up
to the minute. That writes the counter to the phone's storage, so it is done
at most every five minutes, and never on the regular timer.

Sizes are in SI units (1 GB = 1000 MB), like Android's Settings. Android
stores a warning set as "2 GB" as 2 GiB, so it shows here as 2.15 GB.

## What it reads

[`scripts/remote.sh`](scripts/remote.sh) is sent as ssh's stdin and run by
`sh -s`. Everything that needs root runs in one `su`. It prints `ps:` lines,
and [`phone.js`](phone.js) reads them:

| | From |
|---|---|
| Battery | `dumpsys battery`: level, status, plug, temperature, health, and maximum against design capacity for the wear. Without root, `/sys/class/power_supply/battery` |
| Signal | `dumpsys telephony.registry`: the SIM slot in service, its operator, radio technology, and the level (0–4) and dBm of its primary measurement. Android picks the same one for its bars. NR next to LTE shows as 5G |
| Mobile data connected | that slot's data connection state |
| Wi-Fi | `cmd wifi status` |
| Hotspot | `dumpsys tethering`'s tethered interfaces, and their live neighbours (`ip neigh`) as the devices on it |
| Sound | the global `mode_ringer` and `zen_mode` settings |
| Storage | `df /data` |
| Notifications | `dumpsys notification --noredact`: app, time, title, and text (or the expanded text). Group summaries are left out; ongoing ones (services, downloads) are folded under a link |
| Now playing | `dumpsys media_session`: the session that is playing, else the newest active one with something loaded |
| Photos | the four newest in `DCIM/Camera` and `Pictures/Screenshots`, through root's own view of shared storage (`/data/media/0`) |

App names come from a list of common apps. Any other app gets a name made from
its package: `io.heckel.ntfy` → `ntfy`.

The four newest photos are copied over once each, while the popout is open,
into `~/.cache/DankMaterialShell/phoneStatus/photos`. They are deleted again
when newer ones take their place.

A check is one ssh, every 60 s by default, only while the pill is on a bar. On
a phone it takes about a second and a half. ssh runs with `BatchMode=yes`, so
it never asks for anything, and `ControlMaster=no`. An unreachable phone keeps
its last answer on screen, marked with when it was last seen.

```sh
ssh -p 8022 user@phone sh -s < scripts/remote.sh      # see it by hand
dms ipc call phoneStatus status                       # what the pill knows
dms ipc call phoneStatus refresh
dms ipc call phoneStatus ring
```

## Settings

| Setting | Default | |
|---|---|---|
| Phone | none | an SSH Hosts host |
| Check every | 60 s | 30 s – 15 min; opening the popout always checks at once |
| Notification count on the pill | on | |
| Newest photos | on | |

## Installing

```sh
ln -sfn "$PWD/phoneStatus" ~/.config/DankMaterialShell/plugins/phoneStatus
dms ipc call plugin-scan scan
```

Enable **Phone Status** under **Settings → Plugins**, add it to a section under
**Settings → Bar**, and pick the phone in its settings. It needs
[SSH Hosts](../sshManager/) for the host.

## Tests

```sh
qmltestrunner -input tests/tst_phone.qml   # on NixOS add -import <qtdeclarative>/lib/qt-6/qml
```

They check `phone.js` against real probe lines from an Android 16 phone.
