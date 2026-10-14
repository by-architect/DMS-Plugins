# Speed Test

Your internet speed in the bar, from a speed test run on a timer — and, one
click away, the last result in full, where it was measured, and the tests
before it.

```
   bar:   [ ⏲ ↓94 ↑12 ]     the last test, Mbit/s
          [ ⏲ ↓4.2 ↑0.8 ]   amber: the download was under the slow level
          [ ◌ ↓94 ↑12 ]     a test is running (the numbers are the last ones)
          [ ⚠ -- ]          red: the last test failed and none ever worked

   click:
        ┌────────────────────────────────────────────────┐
        │  Speed test                                    │
        │  last test 12 min ago · next in 48 min         │
        │                                                │
        │   Download        Upload         Ping          │
        │   94 Mbit/s       12 Mbit/s      15.1 ms       │
        │                                                │
        │   Server    Turk Telekom · Istanbul (12 km)    │
        │   Provider  Turk Telekom · 203.0.113.7         │
        │   Network   home-wifi                          │
        │   Tested    14:20 with speedtest-cli           │
        │                                                │
        │   Last 24 tests          ━ download ━ upload   │
        │   ╱‾‾╲__╱‾‾‾‾╲___╱‾‾                           │
        │   14:20   ↓ 93.8 Mbit/s  ↑ 12.3 Mbit/s  15.1 ms│
        │   13:20   ↓ 91.2 Mbit/s  ↑ 12.0 Mbit/s  14.8 ms│
        │                                                │
        │   [ Run now ]  Every 1 h · right-click the pill │
        └────────────────────────────────────────────────┘
```

Right-click the pill to run a test now; **Run now** in the popout does the same.

## When it tests

Every hour by default (**Test every**, in minutes; **0** turns automatic tests
off, leaving Run now and the right-click). The clock runs from the start of the
last test, and is kept in the plugin's state file, so a shell restart neither
forgets the results nor runs a test the moment the shell is back.

| | |
|---|---|
| Just after the shell starts | nothing for 90 seconds — the network may still be coming up at login |
| No network at all | nothing; the test waits for one (DMS's network service says when there is none) |
| A test failed | tried again after 10 minutes, or the interval if that is shorter |
| The machine slept through a test | checked every half minute, so it runs soon after waking |
| No pill on any bar | nothing on the timer |

A test downloads and uploads for several seconds each — tens to hundreds of
megabytes on a fast line — so mind the interval on a metered connection.

## Which program runs it

[`scripts/run.sh`](scripts/run.sh) runs whichever is installed, and prints its
JSON:

| Program | Run as | Reads |
|---|---|---|
| Ookla's official `speedtest` | `speedtest --format=json --accept-license --accept-gdpr` | download and upload in bytes/s, ping, jitter, packet loss, server, ISP, external IP |
| `speedtest-cli` (Python, sivel) | `speedtest-cli --json --secure` | download and upload in bit/s, ping, server and its distance, ISP, external IP |
| `librespeed-cli` | `librespeed-cli --json` | download and upload in Mbit/s, ping, jitter, server |

**speedtest-cli is run on the nearest servers.** On its own it picks from a
fixed, global server list (`speedtest-servers-static.php`) that from some
countries holds nothing closer than another continent: from Istanbul its
nearest is in England, 2,500 km and 130 ms away, and the result says more
about that path than about your line. speedtest.net's own web client asks
`/api/js/servers` instead, which lists servers in the same city.
[`scripts/nearest.py`](scripts/nearest.py) runs speedtest-cli's own engine —
the same latency pick, download, upload and JSON — against those five, and
falls back to the usual list when that API does not answer. It finds the
engine next to the `speedtest-cli` program (on NixOS,
`<package>/lib/python3.X/site-packages`) or wherever `python3` already looks;
without it, or without `python3`, the plain `speedtest-cli --json --secure`
runs instead. The popout says "speedtest-cli, nearest server" when it was the
former. On the same café Wi-Fi, England read 15.6 Mbit/s down at 131 ms;
Turkcell 2 km away read 40.9 Mbit/s at 91 ms.

**Automatic** tries them in that order. `speedtest` is two different programs —
Ookla's, and on many systems (NixOS among them) the Python `speedtest-cli`
under a second name — so it is asked which one it is (`speedtest --version`)
before its flags are chosen. `--secure` keeps speedtest-cli on HTTPS, which
some networks are less likely to get in the way of. With none of them
installed, the popout says so instead of failing silently.

A test that does not finish within three minutes is stopped and counts as
failed; the reason in the popout is the program's own `ERROR:` line when it
gave one.

## What is kept

The last 48 successful tests — when, download, upload, ping and jitter, the
server and provider, and the network it ran on (the Wi-Fi name, or Ethernet,
from DMS's network service) — plus when the last attempt was and why it
failed, if it did. They live in DMS's plugin state
(`~/.local/state/DankMaterialShell/plugins/speedTest_state.json`), not in the
settings.

## Seeing what it sees

```sh
dms ipc call speedTest status     # the last result, the last failure, when the next test is
dms ipc call speedTest run        # a test now
dms ipc call speedTest history    # every kept test, newest first, tab separated
```

The parsing, the schedule and the text, outside quickshell:

```sh
node tests/speedtest.test.js           # samples of all three programs' output
node tests/speedtest.test.js --live    # plus one real test (uses the network)
```

## Settings

| Setting | Default | |
|---|---|---|
| Test every | 60 min | 0 = only when asked |
| Slow below | 10 Mbit/s | the pill turns amber when the last download was slower |
| The pill shows | download and upload | or download only, or download, upload and ping |
| Speed test program | automatic | or one of the three by name |

## Installing

```sh
ln -sfn "$PWD/speedTest" ~/.config/DankMaterialShell/plugins/speedTest
dms ipc call plugin-scan scan
dms ipc call plugins enable speedTest
```

Then add **Speed Test** to a bar section under **Settings → DankBar**. Until it
is on a bar, nothing runs on the timer.

## Needs

One of `speedtest-cli`, Ookla's `speedtest` or `librespeed-cli`; `python3`
for speedtest-cli's nearest-server run.

## Shape

`speedtest.js` holds the parsing of all three programs' output, the schedule
and the text, as pure functions tested outside quickshell.
`SpeedTestService` is the singleton that keeps the timer, runs
`scripts/run.sh` through `CommandWorker` (a copy of processWidget's: one
command at a time, a timeout, every `Process` destroyed when it is done) and
stores the history. The pill (`SpeedTestWidget.qml`) and the popout are layout
over the service.
