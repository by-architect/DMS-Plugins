# Command Runner

A DankMaterialShell launcher plugin. Add commands with a name in the plugin's
settings, then type `run <name>` in the launcher to find and launch them.

```
run lock       →  runs "Lock screen" if that's what you named it
run            →  lists every configured command
```

## Install

Symlink it into the DMS plugin directory:

```sh
ln -s "$PWD/commandRunner" ~/.config/DankMaterialShell/plugins/commandRunner
```

The shell picks it up on its own (it watches the plugins directory). Enable
**Command Runner** under Settings → Plugins, then add commands under that same
settings panel.

## Adding commands

Settings → Plugins → Command Runner → Commands. Each entry has:

| Field | Required | Notes |
|---|---|---|
| Name | Yes | What you'll search for after the trigger |
| Command | Yes | Runs via `sh -c`, so pipes, redirects and quoting all work |
| Icon | No | `material:<name>`, `unicode:<char>`, or a desktop icon theme name. Defaults to `material:terminal` |

Example — a screenshot-to-clipboard command needs the shell for its pipe:

```
Name:    Screenshot region
Command: grim -g "$(slurp)" - | wl-copy
```

Commands are stored in this plugin's settings, not in the repo — nothing here
needs editing to add or remove one.

## Behavior

- `getItems(query)` filters your configured commands by name or command text
  (case-insensitive substring match); an empty query lists all of them.
- Selecting one runs `sh -c "<command>"` via `Quickshell.execDetached` —
  fire-and-forget, same as the launcher's own app entries. Output isn't
  captured; use a command that notifies or writes to a file if you need to see
  the result.
- Right-click (or the action panel) offers "Copy command" for pasting
  elsewhere.
- No commands configured yet, or nothing matches the query, both show an
  explanatory row instead of an empty list.
- Editing the command list while the launcher is open refreshes it immediately
  — no rescan or reload needed.

## Trust boundary

Commands run exactly as typed, with no sanitization — that's the point, it's a
personal command launcher, not something that accepts untrusted input. Anyone
who can write to this plugin's settings (i.e. anyone with your user account)
can already run arbitrary commands anyway. Don't paste commands from sources
you wouldn't otherwise run.
