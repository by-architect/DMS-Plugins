# Nix Search

A DankMaterialShell launcher plugin. Type `nix <query>` in the launcher to search
nixpkgs by package name and description.

```
nix firefox        →  firefox, firefox-esr, firefox-mobile, …
nix json cli       →  packages matching both words
nix c++            →  metacharacters are literal, not regex
```

## Install

Symlink it into the DMS plugin directory and rescan:

```sh
ln -s "$PWD/plugins/nixSearch" ~/.config/DankMaterialShell/plugins/nixSearch
dms ipc call plugin-scan scan
```

Then enable **Nix Search** under Settings → Plugins. Removing the symlink
uninstalls it.

## How it works

`nix search <flake> <regex...> --json`, run as a child process.

The launcher's plugin interface is synchronous — `getItems(query)` has to return
an array immediately — so the search never runs inline. `getItems()` returns
whatever is already cached for the query (or a status row), schedules the real
search behind a debounce timer, and when the process exits the results go into
the cache and the launcher is asked to re-query via
`PluginService.requestLauncherUpdate()`.

Two things about `nix search` shape the design:

- **The first search is slow.** It evaluates all of nixpkgs, which takes about a
  minute. Every later search reuses that eval cache and takes ~2 seconds. The
  status row says so after 4 seconds, so the wait doesn't look like a hang.
- **That first run is the expensive part.** An in-flight search is therefore
  never killed to start a newer one — doing so would discard exactly the work
  that makes subsequent searches fast. The newest pending query is queued and
  runs as soon as the current one finishes. Only the timeout kills a process.

Results are ranked locally rather than left in `nix search`'s order: exact
attribute match, then prefix, then substring, then description hits, with
shorter attributes preferred. Attributes inside a language ecosystem
(`haskellPackages.terminal`, `python3Packages.requests`) sort below every
top-level attribute — searching `terminal` should not lead with a Haskell
library. The ranking is passed through as `_preScored` so the launcher's own
scorer keeps it instead of re-sorting and dropping description-only matches.

Per-query results are cached (40 queries, LRU), so backspacing through a query
is instant.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Trigger | `nix ` | Trailing space is deliberate — it stops `nixos-rebuild` from matching |
| Flake reference | `nixpkgs` | Pin it, e.g. `github:NixOS/nixpkgs/nixos-25.05` |
| nix binary | `nix` | Absolute path if `nix` isn't on the shell's PATH |
| Enter key action | Copy attribute | Or copy `nixpkgs#attr`, `nix run`, or open search.nixos.org |
| Result limit | 50 | Broad queries match hundreds of packages |
| Typing delay | 300 ms | Debounce before launching `nix search` |
| Minimum characters | 2 | Below this, queries match too much of nixpkgs |
| Search timeout | 120 s | Sized for the cold-cache first run |
| Offer profile install | off | Adds `nix profile add` to the right-click menu |

Right-click (or the action panel) on any result for: copy attribute, copy
installable, run without installing, open on search.nixos.org, and — if enabled
— install to the user profile.

## Requirements

`nix` with the `nix-command` and `flakes` experimental features. The plugin
passes `--extra-experimental-features "nix-command flakes"` itself, so it works
even where they aren't enabled globally. A startup check blocks activation with
an explanatory toast if the configured `nix` binary isn't found.

Note that `nix profile add` is the Nix 2.30+ spelling; on older Nix use
`nix profile install` instead, or leave that action disabled.
