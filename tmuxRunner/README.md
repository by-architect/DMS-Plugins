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

Each configured host is also probed in the background for tmux sessions
already running *on it* -- so if `prod` already has a `deploy` session going,
`tmux prod` lists `prod / deploy` directly instead of just an entry that
would start a second, unrelated one. Picking it wraps the same
ssh-in-tmux pattern as above, but tells the remote tmux to attach to that
session by name. A plain "New session on prod" entry stays available
alongside it for starting another one.

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
- An SSH host's plain "connect" entry only shows up here while it has no
  matching tmux session running locally — the session name is derived from
  the host (`ssh-<name>`, sanitized), so reselecting it later reattaches to
  the same session rather than creating a new one. Once that session exists
  it's found and killed the same way as any other, and sshManager's own
  launcher is untouched — this only adds hosts into tmux's own search.
- Remote sessions are discovered by actually connecting to each host in the
  background — non-interactively, one host at a time, no more than every 20
  seconds and only while the launcher is in use, since each check is a real
  network round trip rather than a local command. Key-based hosts connect
  straight away (and fail silently back to the plain entry if the agent or
  default identity doesn't work, same as a normal `ssh` would). Password
  hosts are only probed when sshManager has a password stored for them *and*
  `sshpass` is on PATH — the password comes from sshManager's daemon and is
  passed through the process environment, never argv, the same way
  sshManager's own README asks any consumer to handle it. A host that can't
  be probed for either reason just keeps showing the plain "connect" entry,
  same as before this existed.
- Selecting a discovered remote session opens the same interactive `ssh` (in
  a terminal, tmux-wrapped) as the plain connect entry — it never uses a
  stored password for that part, only the background probe does. The remote
  side is told to `tmux attach -t <session>` instead of opening a shell.

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

Optionally, `sshpass` — only needed to discover remote sessions on
password-authenticated sshManager hosts. Everything else (key-based hosts,
the plain connect entries, sshManager itself) works without it.
