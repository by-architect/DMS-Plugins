# Process Runner

A DankMaterialShell launcher plugin. Type `kill <name>` to find a running
process and kill it, or just `kill` to see the heaviest processes on the
system right now, sorted by CPU usage.

```
kill            →  the top processes by CPU usage, no query needed
kill chrome     →  processes matching "chrome" (searches the full command
                    line, not just the short name)
```

## Install

```sh
ln -s "$PWD/processRunner" ~/.config/DankMaterialShell/plugins/processRunner
```

The shell picks it up on its own. Enable **Process Runner** under Settings →
Plugins.

## Behavior

- Backed by `ps -eo pid,user,pcpu,pmem,args --sort=-pcpu`. Like tmuxRunner's
  session list and musicRunner's playlist list, the process table doesn't
  depend on what's typed, so it's polled (every 2s) and filtered locally
  instead of re-run per keystroke — searching is instant and doesn't spawn
  anything.
- The display name comes from the full command line, not the kernel's
  16-character `comm` field — on NixOS especially, `comm` is often a
  truncated, generically-named wrapper script (`.ghostty-wrappe`,
  `.quickshell-wra`), while the real command line's first argument resolves
  to something actually recognizable (`ghostty`, `quickshell`). Kernel
  threads, which have no real command line, keep `ps`'s own bracketed form
  (e.g. `[kworker/u89:9-events_unbound]`).
- `%CPU` here is `ps`'s own figure: a decaying average over the process's
  lifetime, not the instantaneous per-second number `top`/`htop` compute
  from two samples. It's a fine way to sort "what's been heavy," just don't
  expect it to match `htop` number-for-number.
- Processes at or above the "hot" CPU threshold get a distinct icon (a flame
  instead of the default) so heavy hitters stand out while scanning the
  list.
- Its own `ps` call is filtered out of the results — otherwise every refresh
  would show a fresh `ps` process momentarily measuring itself at a high
  CPU%, which is noise, not a real answer to "what's using my CPU."

## Selecting a result

1. **Kill (SIGTERM)** — the Enter default. A request, not a guarantee: a
   process can catch and ignore SIGTERM, so this may not actually end it.
   `kill <pid>`
2. **Force kill (SIGKILL)** — right-click only. Can't be caught or ignored.
   `kill -9 <pid>`

Right-click also offers **Copy PID** and **Copy command line**.

Every kill re-verifies the target immediately beforehand (`ps -p <pid>`),
for two reasons: the process may have already exited (and its PID reused for
something else entirely) since the list was last refreshed, and this is
where the one safety rail below is enforced. `kill`'s own exit code decides
what the toast says — a failed signal (e.g. trying to kill another user's or
root's process without privilege) is reported as a failure, not silently
assumed to have worked.

## Safety

This plugin never uses `sudo` or any other privilege escalation — `kill` can
only ever affect processes your own account already owns, exactly as if you
ran it from a terminal. Nothing here changes that boundary.

The one thing it actively refuses, checked fresh on every kill attempt
regardless of signal: **killing the quickshell process running this very
launcher.** Ending your own desktop session by fat-fingering a select in its
own launcher is the one mistake worth actively preventing. Everything else
your account can `kill` is your call, the same as it would be from a
terminal — this plugin doesn't maintain a list of "important" processes to
second-guess you about.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Trigger | `kill ` | Trailing space stops it firing on unrelated words |
| Results shown | 15 | Heaviest CPU usage first |
| "Hot" CPU threshold | 50% | Processes at or above this get the flame icon |
| ps binary | `ps` | Absolute path if not on the shell's PATH |
| kill binary | `kill` | Absolute path if not on the shell's PATH — must be the standalone binary, not a shell builtin (this plugin calls it directly, not through a shell) |

## Requirements

`ps` and a standalone `kill` binary (procps/util-linux; virtually always
present on a Linux desktop). A startup check verifies both configured
binaries are on PATH before the trigger goes live, and says which one is
missing if not.
