# Music Runner

A DankMaterialShell launcher plugin. Type `mpd <query>` to search your MPD
library and current playback queue across six categories at once — songs,
playlists, artists, albums, songs found inside your saved playlists, and
what's already in your queue — all in one ranked, mixed list. Each category
can be turned off independently in settings, or you can scope a single search
to just one category on the fly.

```
mpd kanye        →  songs, an artist, and albums all named/matching "kanye"
mpd l rap        →  only Lists, searching for "rap"
mpd              →  browse your saved playlists (nothing typed yet)
```

## Install

```sh
ln -s "$PWD/musicRunner" ~/.config/DankMaterialShell/plugins/musicRunner
```

The shell picks it up on its own. Enable **Music Runner** under Settings →
Plugins, then adjust which categories search in that same panel.

## Categories

| Category | Setting | What it searches |
|---|---|---|
| Musics | Musics | Song titles and artists (`mpc search any`) |
| Lists | Lists | Saved playlist names |
| Artists | Artists | Artist names |
| Albums | Albums | Album names |
| Musics in Lists | Musics in Lists | Songs *inside* your saved playlists specifically |
| Now Playing | Now Playing | Songs already in your current playback queue |

All six are on by default; turn any off in the plugin's settings.

## Scoping a search to one category

Follow the trigger with a short prefix and a space to search just one
category for that search, regardless of what's toggled on in settings:

| Prefix | Category | Also accepts |
|---|---|---|
| `s` | Musics | `song`, `songs`, `music`, `musics` |
| `l` | Lists | `list`, `lists`, `playlist`, `playlists` |
| `ar` | Artists | `artist`, `artists` |
| `al` | Albums | `album`, `albums` |
| `q` | Now Playing | `queue`, `now`, `playing`, `nowplaying` |

```
mpd l rap        →  only Lists
mpd s kanye      →  only Musics
mpd q solo       →  only Now Playing
```

This overrides the settings toggles for that one search, including a
category you've turned off — a quick way to reach it without opening
settings. `mpd l` or `mpd q` with nothing after the prefix browses that
category (same as opening the trigger with no query at all, just scoped).

## Why one plugin, not six separate result sections

The launcher gives every plugin exactly one titled results group — there's no
way for a single plugin to produce several independently-headed sections the
way built-in "Applications" and "Browse" are. So every category shares one
list, each result labeled by icon and a type comment instead of sitting under
separate headers. There's also no per-item icon color available to a plugin —
checked directly against `AppIconRenderer.qml`, which has no color property
at all — so categories are told apart by icon shape only (♪ song/track,
▤ playlist, person artist, album album, ▶ queue), not color.

## Lists and Musics in Lists show the list name with its matching tracks underneath

A result row is a single elided line, for every plugin in this launcher —
there's no per-item multi-line layout to opt into, and no way for a plugin to
resize it. So "list name, then each matching track on its own line
underneath" is built from several single-line rows instead of one row
spanning several lines:

```
Second Playlist                ← header: acts on the whole playlist
        - CLar                  ← label only, not selectable on its own
        - CLarify
        - CLient
```

A playlist matched by its own name (no track match) shows just the header,
with a track count instead of a track list:

```
Rap Sert
  6 tracks
```

**Selecting anything here always acts on the playlist as a whole** — the
header row runs Replace/Add to end/Add after current on every track in the
list (see below), never on one song individually. The track labels
underneath are visible so you can see *what* matched, but aren't independent
actions; if you want to act on one specific song, find it under **Musics**
instead. Up to 5 matching tracks are listed per playlist, with a
"+N more tracks" label if there were more.

One caveat: this launcher can only skip *whole section headers* during
keyboard navigation, not individual rows — so arrow keys will still stop on a
track label. Pressing Enter there does nothing (correctly), it's just not
skipped over the way a true header would be.

## Why "Musics in Lists" and "Now Playing" are slower to update

`mpc search` doesn't look inside saved playlists or the current queue — those
need reading each playlist's contents, or the whole queue, individually. So
instead of a live per-keystroke search, this plugin polls: playlist names and
the current queue refresh roughly every 8s, and the full playlist-tracks
index (fetched by walking every playlist, one at a time) refreshes roughly
every 30s. `getItems()` always answers instantly from whatever's cached; a
poll landing just updates it for the next search. Turn a category off if you
don't use it, to skip that background work entirely.

## Selecting a result

Enter always runs the **first** action listed below for that result's type.
Right-click (or the action panel) shows the full list, in the same order, so
any of them is one click away.

**Songs, Lists (including Musics in Lists), Artists, and Albums** all share
the same three actions, applied to the song, the whole playlist, or every
matching song by that artist/album:

1. **Replace queue and play** — this is the default specifically because
   picking a result usually means "I want to listen to this now", the way
   clicking an album's play button works in most music apps.
   `mpc clear && mpc add|load|findadd ... && mpc play`
2. **Add to end of queue**
   `mpc add <file>` / `mpc load <name>` / `mpc findadd artist|album <name>`
3. **Add after current song** — inserts the song, or the whole
   playlist's/artist's/album's tracks as a block, right after what's
   currently playing, in order. For playlists/artists/albums, mpc has no
   server-side "insert by name" command, so this resolves the matching file
   list first, then inserts it (capped at 30 tracks so a huge artist catalog
   doesn't chain 200 processes together).

**Now Playing** results only have one action, since the song is already
queued:

1. **Play this song now** — jumps straight to it (`mpc play <position>`).
   Nothing is added, removed, or reordered.

Right-click also adds **Copy file path** (songs, Now Playing) or **Copy
name** (everything else).

**"Replace queue and play" is the default for everything except Now Playing**
— a deliberate choice: picking a result plays it immediately, the rest of
your queue included. If you'd rather not interrupt what's playing, "Add to
end of queue" is one right-click away.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Trigger | `mpd ` | Trailing space stops it firing on unrelated words; see Scoping above for category prefixes |
| Musics / Lists / Artists / Albums / Musics in Lists / Now Playing | all on | Independent toggles; a scope prefix overrides these for one search |
| Results per category | 6 | Cap before the combined list is ranked and shown |
| mpc binary | `mpc` | Absolute path if not on the shell's PATH |
| MPD host / port | *(blank)* | Blank uses the `MPD_HOST`/`MPD_PORT` environment variables, same as running `mpc` yourself. Only set these if the shell process doesn't already have them (e.g. a different systemd user session) |

## Requirements

`mpc`. MPD itself does **not** need to be reachable for the plugin to enable —
only the `mpc` binary being on PATH is checked at startup, since MPD being
down is a normal, recoverable state (a remote server rebooting, a laptop
closed), not a reason to make the whole plugin unusable until it happens to
be up at the exact moment you enable it.

Connectivity is checked continuously at runtime instead. If MPD can't be
reached, the launcher shows **"MPD not connected"** — with the actual reason
(connection refused, timed out, etc.) and "Press Enter to retry" — right in
the results, as soon as you open the trigger, before you've even typed
anything. It clears itself automatically the moment a search or the
background poll succeeds again; there's nothing to re-enable or reload once
MPD comes back. Every mpc call (search, poll, and the resolve-then-insert
action lookups) is timeout-bounded for the same reason the old startup check
was: connecting to an unreachable host can hang for a long time instead of
failing fast, and none of them should get stuck waiting on that forever.
