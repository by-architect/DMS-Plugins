# Music Runner

A DankMaterialShell launcher plugin. Type `mpd <query>` to search your MPD
library across five categories at once — songs, playlists, artists, albums,
and songs found inside your saved playlists — all in one ranked, mixed list.
Each category can be turned off independently in settings.

```
mpd kanye        →  songs, an artist, and albums all named/matching "kanye"
mpd              →  browse your saved playlists (nothing typed yet)
```

## Install

```sh
ln -s "$PWD/musicRunner" ~/.config/DankMaterialShell/plugins/musicRunner
```

The shell picks it up on its own. Enable **Music Runner** under Settings →
Plugins, then adjust which categories search in that same panel.

## Why one plugin, not five separate result sections

The launcher gives every plugin exactly one titled results group — there's no
way for a single plugin to produce several independently-headed sections the
way built-in "Applications" and "Browse" are. So all five categories share one
list, each result labeled by icon and a type comment instead of sitting under
separate headers.

## Categories

| Category | Setting | What it searches |
|---|---|---|
| Musics | Musics | Song titles and artists (`mpc search any`) |
| Lists | Lists | Saved playlist names |
| Artists | Artists | Artist names |
| Albums | Albums | Album names |
| Musics in Lists | Musics in Lists | Songs *inside* your saved playlists specifically |

All five are on by default; turn any off in the plugin's settings.

## Lists and Musics in Lists show one row per playlist

A result row is a single elided line — this launcher has no real multi-line
row, for any plugin — so a playlist can't render as a title with its matching
tracks indented underneath it. Instead: **a playlist that matches, whether by
its own name or by a track found inside it, is always exactly one row.**
Selecting it acts on the playlist as a whole, never on one track inside it —
if you want a specific song, find it under **Musics** instead.

The subtitle shows what matched:

```
Rap Sert                    ← name itself matches "rap"
  6 tracks

Second Playlist              ← matched via a track inside it
  CLar • CLarify • CLient
```

Up to 3 matching track titles are shown, bullet-separated, with "+N more" if
there were others. If the match was on the playlist's own name rather than a
track inside it, the subtitle shows the track count instead.

## Why "Musics in Lists" is slower to update

`mpc search` doesn't look inside saved playlists — that requires reading each
playlist's contents individually. So instead of a live per-keystroke search,
this plugin polls: playlist names refresh roughly every 8s, and the full
playlist-tracks index (fetched by walking every playlist, one at a time)
refreshes roughly every 30s. `getItems()` always answers instantly from
whatever's cached; a poll landing just updates it for the next search. Turn
the category off if you don't use it, to skip that background work entirely.

## Selecting a result

Enter always runs the **first** action listed below for that result's type.
Right-click (or the action panel) shows the full list, in the same order, so
any of them is one click away.

**Songs** (from the Musics category):

1. **Add after current song and play** — cuts the queue, starts playing this
   song immediately, and everything already queued still plays afterward.
   `mpc insert <file> && mpc next`
2. **Add after current song** — same insert, without jumping to it.
   `mpc insert <file>`
3. **Replace queue and play** — clears the queue first.
   `mpc clear && mpc add <file> && mpc play`
4. **Add to end of queue**
   `mpc add <file>`

**Playlists** (Lists and Musics in Lists), **Artists**, and **Albums** all
share the same three actions, applied to the whole playlist or every matching
song:

1. **Replace queue and play** — this is the default specifically because
   picking a playlist/artist/album usually means "I want to listen to this
   now", the way clicking an album's play button works in most music apps.
   `mpc clear && mpc load <name> && mpc play` (or `findadd` for artist/album)
2. **Add to end of queue**
   `mpc load <name>` / `mpc findadd artist|album <name>`
3. **Add after current song** — inserts the whole playlist/artist's/album's
   tracks as a block right after what's currently playing, in order. mpc has
   no server-side "insert a playlist/artist/album" command, so this resolves
   the matching file list first, then inserts it (capped at 30 tracks so a
   huge artist catalog doesn't chain 200 processes together).

Right-click also adds **Copy file path** (songs) or **Copy name** (everything
else).

**Nothing here defaults to something destructive for songs** — inserting one
song doesn't touch the rest of your queue. Replacing the queue is only the
default for playlist/artist/album selections, and even then it's one right-click
away from "add to end" instead if you'd rather not interrupt what's playing.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Trigger | `mpd ` | Trailing space stops it firing on unrelated words |
| Musics / Lists / Artists / Albums / Musics in Lists | all on | Independent toggles |
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
background playlist poll succeeds again; there's nothing to re-enable or
reload once MPD comes back. Every mpc call (search, poll, and the
resolve-then-insert action lookups) is timeout-bounded for the same reason
the old startup check was: connecting to an unreachable host can hang for a
long time instead of failing fast, and none of them should get stuck waiting
on that forever.
