# SSH Hosts

A DankMaterialShell composite plugin. It keeps a list of SSH connections --
name, host, port, username, auth method -- entered once in its settings, and
puts that list to use two ways: its own launcher (`ssh <name>`) to connect
from a terminal, and a small API any other plugin can call to build the same
connection itself.

```
ssh            →  every configured host
ssh prod       →  hosts matching "prod" by name, address or username
```

## Install

```sh
ln -s "$PWD/sshManager" ~/.config/DankMaterialShell/plugins/sshManager
```

The shell picks it up on its own. Enable **SSH Hosts** under Settings →
Plugins, then add hosts under its settings panel.

## Settings

Each host has a name (optional -- falls back to the host address), a host or
IP, a port (default 22), a username, and an auth method:

- **Key (recommended)** -- optionally point at a specific identity file
  (`~/.ssh/id_ed25519`); leave it blank to let `ssh` resolve the default
  identity and your agent as it normally would.
- **Password** -- optionally store a password so other plugins can use it
  non-interactively (see below). The launcher itself never uses the stored
  password: connecting through `ssh <name>` always opens a terminal and lets
  `ssh` prompt for it interactively, the same as typing the command by hand.

Once saved, a password is never shown again in this screen -- only whether
one is stored. Change or clear it from the host's row.

## Where your data lives

| What | Where | Notes |
|---|---|---|
| Host list (name, host, port, username, auth method, identity file path) | `~/.config/DankMaterialShell/plugin_settings.json` | Ordinary plugin settings, same file every plugin's config lives in |
| Stored passwords | `~/.local/share/DankMaterialShell/plugins/sshManager/secrets.json`, mode 0600 | Kept out of the settings file so a shared dotfiles repo or a quick `cat plugin_settings.json` doesn't hand out a password with everything else |

That secrets file is still **plaintext**, readable by your own user account.
There is no sandbox between plugins here -- any other enabled plugin can ask
this one for a stored password, exactly the way commandRunner already runs
whatever you configure it to run. Prefer key-based auth; only store a
password for a host where that's genuinely not an option, and treat that
file the way you'd treat an SSH private key with no passphrase.

## For other plugins (e.g. a runner)

Reach this plugin's daemon instance the same way chatManager's providers
reach it:

```qml
readonly property var sshManager: {
    const instances = pluginService?.pluginDaemonInstances ?? ({});
    return instances["sshManager"] ?? null;
}
```

Since a daemon instance only exists once the plugin is loaded, bind to it
reactively (as above) rather than looking it up once -- it will resolve
itself the moment SSH Hosts finishes loading, in whatever order plugins come
up in.

Once you have it:

| Call | Returns |
|---|---|
| `getHosts()` | Every configured host (id, name, host, port, username, authMethod, identityFile, hasPassword) |
| `getHost(id)` | One host by id, or `null` |
| `findHostByName(name)` | One host by its configured name, or `null` |
| `hasPassword(id)` | Whether a password is stored for that host |
| `getPassword(id)` | The stored password, or `""` |
| `buildSshArgs(id)` | A ready argv, e.g. `["ssh", "-p", "2222", "-i", "/home/x/.ssh/id", "user@host"]` -- excludes password auth, since that only makes sense combined with how *you* intend to run it |

`getPassword` is handed over as plainly as everything else in this system --
no extra prompt, no separate grant. If you use it to drive `ssh`
non-interactively, pass it through a `Process`'s `environment` (e.g.
`sshpass -e ssh ...`), not as a command-line argument, so it doesn't end up
sitting in `ps` output for anyone else on the machine to read.

## Implementation notes

- The launcher never touches the daemon or the secrets file, on purpose --
  connecting is always `ssh` in a terminal with the non-secret fields filled
  in, and ssh already knows how to prompt for a password itself. This means
  the launcher works immediately even if the daemon hasn't finished spawning
  yet.
- The settings screen does not reuse the shared `ListSettingWithInput`
  widget other launcher plugins use for their lists (see commandRunner):
  that widget echoes every field of every row back as plain text in its
  "Current Items" list, which is exactly wrong for a password. This plugin's
  settings screen never displays a stored password back to you.
- Terminal detection mirrors tmuxRunner's: eleven common terminals
  (ghostty, kitty, alacritty, foot, wezterm, gnome-terminal, xterm, konsole,
  st, terminator, xfce4-terminal) are auto-detected; anything else falls
  back to `-e`, or set the exec flags yourself in settings.

## Requirements

An `ssh` client. A startup check verifies it's on PATH before the plugin
enables, and says so if not.

A terminal emulator is needed too, to actually connect, but it is
deliberately **not** part of that check: Settings can't be opened until a
plugin passes its startup check, so gating on the terminal default
(`ghostty`) would lock out anyone without it before they could ever reach the
setting that changes it. If your terminal isn't ghostty, set it under this
plugin's settings before using the launcher -- connecting with the wrong
terminal configured just does nothing, silently.
