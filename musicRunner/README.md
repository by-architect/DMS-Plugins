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
list, each result labeled by icon and a type comment (`Song · Artist`,
`Playlist`, `Artist`, `Album · Artist`, `In: Playlist Name`) instead of
sitting under separate headers.

## Categories

| Category | Setting | What it searches |
|---|---|---|
| Musics | Musics | Song titles and artists (`mpc search any`) |
| Lists | Lists | Saved playlist names |
| Artists | Artists | Artist names |
| Albums | Albums | Album names |
| Musics in Lists | Musics in Lists | Songs *inside* your saved playlists specifically — shown as "In: \<playlist name\>" so you can tell a library-wide match from one found through a particular playlist |

All five are on by default; turn any off in the plugin's settings.

## Why "Musics in Lists" is slower to update

`mpc search` doesn't look inside saved playlists — that requires reading each
playlist's contents individually. So instead of a live per-keystroke search,
this plugin polls: playlist names refresh roughly every 8s, and the full
playlist-tracks index (fetched by walking every playlist, one at a time)
refreshes roughly every 30s. `getItems()` always answers instantly from
whatever's cached; a poll landing just updates it for the next search. Turn
the category off if you don't use it, to skip that background work entirely.

## Selecting a result

Enter runs the action configured in settings — **Enqueue** (default, adds to
the end of the current queue) or **Play now** (clears the queue and plays
immediately). Right-click always offers both, plus **Play next** (inserts
right after the currently playing track) for individual songs.

| Result type | Enqueue does | Play now does |
|---|---|---|
| Song / song-in-playlist | `mpc add <file>` | clear, add, play |
| Playlist | `mpc load <name>` (appends the whole playlist to the queue) | clear, load, play |
| Artist | `mpc findadd artist <name>` (all matching songs) | clear, findadd, play |
| Album | `mpc findadd album <name>` (all tracks) | clear, findadd, play |

**Enqueue never clears your queue or interrupts what's playing** — that's the
default specifically so browsing/adding music doesn't take over playback
someone else might be listening to. "Play now" is opt-in, either as your
configured Enter action or explicitly from the right-click menu.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Trigger | `mpd ` | Trailing space stops it firing on unrelated words |
| Musics / Lists / Artists / Albums / Musics in Lists | all on | Independent toggles |
| Results per category | 6 | Cap before the combined list is ranked and shown |
| Enter key action | Enqueue | Or Play now |
| mpc binary | `mpc` | Absolute path if not on the shell's PATH |
| MPD host / port | *(blank)* | Blank uses the `MPD_HOST`/`MPD_PORT` environment variables, same as running `mpc` yourself. Only set these if the shell process doesn't already have them (e.g. a different systemd user session) |

## Requirements

`mpc`, and a reachable MPD server. A startup check verifies the configured
`mpc` binary is on PATH, then tries an actual connection (5s timeout) before
letting the trigger go live — useful specifically because `MPD_HOST` can point
at a remote server, and connecting to an unreachable one doesn't fail fast, it
can hang. If the check fails you'll see one of two distinct messages: mpc
missing, or MPD unreachable.
