# Tmux Runner

A DankMaterialShell launcher plugin. Type `tmux <query>` to find a running
tmux session by name and attach to it, or type a name that doesn't exist yet
to create one.

```
tmux            →  lists every running session, plus configured SSH hosts
tmux dms        →  sessions matching "dms"
tmux prod       →  an SSH host named "prod" (see sshManager) with no session yet
tmux new-thing  →  no session named that → offers "Create \"new-thing\""
```

If the [sshManager](../sshManager/) plugin is installed and has hosts
configured, they're searchable here too. Selecting one runs `tmux new-session`
with `ssh` as the session's command, instead of a shell -- so the connection
gets tmux's detach/reattach for free, and reappears as an ordinary tmux
session (same name, `ssh-<host>`) the next time you look.

## Install

```sh
ln -s "$PWD/tmuxRunner" ~/.config/DankMaterialShell/plugins/tmuxRunner
```

The shell picks it up on its own. Enable **Tmux Runner** under Settings →
Plugins.

## Behavior

- Sessions are listed via `tmux list-sessions`, which doesn't depend on the
  query — it's the same command every time, filtered client-side. So instead
  of a per-keystroke search, the list is polled (throttled to once per
  second) and `getItems()` always answers from cache. First call after
  enabling shows "Loading tmux sessions…" until that first poll lands.
- Attaching or creating opens a terminal running `tmux attach-session` /
  `tmux new-session`, since both need an interactive TTY that can't run
  inside the launcher itself.
- If nothing matches an exact existing session name, a "Create …" row is
  appended below the real matches — existing sessions are offered first, new
  ones only shown as a fallback.
- Right-click (or the action panel) on a real session offers "Copy session
  name" and "Kill session".
- No sessions running at all shows a status row rather than an empty list.
- An SSH host only shows up here while it has no matching tmux session
  running — the session name is derived from the host (`ssh-<name>`,
  sanitized), so reselecting the same host later reattaches to the same
  session rather than creating a new one. Once that session exists it's
  found and killed the same way as any other, and sshManager's own launcher
  is untouched — this only adds hosts into tmux's own search.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Trigger | `tmux ` | Trailing space stops it firing on unrelated words |
| tmux binary | `tmux` | Absolute path if not on the shell's PATH |
| Terminal | `ghostty` | Whatever terminal you actually use |
| Terminal exec flags | *(blank = auto-detect)* | Only needed if your terminal isn't in the built-in list below, or needs different flags |

Auto-detected terminals (blank flags field): ghostty, kitty, alacritty, foot,
wezterm, gnome-terminal, xterm, konsole, st, terminator, xfce4-terminal.
Anything else falls back to `-e`, which covers most others too. If yours
needs something specific, set it directly — e.g. `start --` for a terminal
that only accepts that form.

## Requirements

`tmux`, and a terminal emulator that can run a command via a flag (`-e`, or
similar). A startup check verifies both the configured tmux binary and the
configured terminal are on PATH before the trigger goes live, and says which
one is missing if not.
