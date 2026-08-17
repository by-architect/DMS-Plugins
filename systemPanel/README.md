# System Panel

A fullscreen 3×3 system panel for Phoenix / DankMaterialShell, focused on
answering "who has touched this machine, and is it healthy?".

## Tiles

| | | |
|---|---|---|
| **Login History** — every successful login plus failed SSH attempts, with user, method, source host and relative time | **Inbound SSH** — live remote sessions, plus any established `:22` connection with no matching login session | **Tailscale** — every device in the tailnet, online state, address, direct/relay path, last seen |
| **Boot Health** — recent boots with runtime, clean/unclean status, and the error lines for boots that ended badly | **Local Sessions** — systemd-logind sessions on this seat | **Privilege Escalation** — sudo activity including denied attempts |
| **System Overview** — host, OS, kernel, uptime, systemd state, firewall, sshd, tailscale address | **Failed Units** — `systemctl --failed` and overall system state | **Listening Ports** — what this box exposes, and to which address |

## Data sources

Everything runs as the logged-in user; no root and no helper daemon.

| Tile | Source |
|---|---|
| Login history (successes) | `last -w --time-format iso` (wtmp) |
| Login history (failures) | `journalctl -t sshd -t sshd-session` |
| Boot health | `journalctl --list-boots` + `journalctl -t systemd-shutdown` |
| Tailscale | `tailscale status --json` |
| Inbound SSH | `loginctl show-session` + `ss -tnH state established '( sport = :22 )'` |
| Local sessions | `loginctl show-session` |
| Privilege escalation | `journalctl -t sudo` |
| Failed units | `systemctl list-units --failed --output=json` |
| Listening ports | `ss -tulnHp` |
| Overview | `hostname`, `uname`, `/proc/uptime`, `/etc/os-release`, `systemd-analyze`, `systemctl is-active` |

Failed logins come from the journal rather than `lastb`, because `/var/log/btmp`
is root-only. Nothing is lost — sshd records invalid users and failed auth there.

A boot counts as **unclean** when its boot id never logged a `systemd-shutdown`
message. Error context is fetched only for those boots, one at a time, so a long
boot history does not fan out into dozens of processes.

## Install

The plugin is not installed automatically. Symlink `plugins/systemPanel` into
`~/.config/DankMaterialShell/plugins/` and enable it:

```sh
ln -sfn "$PWD/plugins/systemPanel" ~/.config/DankMaterialShell/plugins/systemPanel
SHELL_PATH=$(quickshell list --all | grep -oE '/run/user/[0-9]+/danklinux-shell/[a-f0-9]+' | head -1)
quickshell -p "$SHELL_PATH" ipc call plugin-scan scan
quickshell -p "$SHELL_PATH" ipc call plugins enable systemPanel
```

Then add the **System Panel** widget to the bar under Settings → DankBar, or
bind the IPC call below to a key.

## Usage

```sh
quickshell -p <shell-path> ipc call systemPanel toggle   # also: open, close, status
```

`status` reports whether the panel holds keyboard focus (`keyboard=ready`),
which is useful when debugging compositor focus behaviour.

Inside the panel: **Esc** or **q** closes, **Ctrl+R** / **F5** refreshes.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `autoRefresh` | `true` | Re-run every collector every 30s while open |
| `journalDays` | `30` | How far back to read the journal for failed logins and sudo activity |

## Implementation notes

Two things about the plugin system are worth knowing before editing this:

1. **A `PanelWindow` declared inline inside a `PluginComponent` never becomes a
   layer surface.** It has to be created by a `LazyLoader` (as here) or
   `createObject(null)`. There is no error message when you get this wrong — the
   window is simply never mapped.

2. **On Hyprland, layer-shell exclusive keyboard focus is ignored** by the shell's
   default configuration, which uses `hyprland_focus_grab` instead. The window
   mirrors the shell's own policy via `KeyboardFocus.keyboardFocus()` plus
   `DankFocusGrab`; hardcoding `WlrKeyboardFocus.Exclusive` silently leaves the
   panel unable to receive Esc.

Reloading during development is also worth noting: `plugin-scan reload` only
cache-busts the plugin's **entry** component. Nested files (`SystemPanelWindow.qml`,
`SystemData.qml`, the tiles) stay in the QML type cache, so edits to them do not
take effect until the shell restarts — or until the plugin is mounted under a new
directory name, which changes every nested URL.
