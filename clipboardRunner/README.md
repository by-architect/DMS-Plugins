# Clipboard Runner

A DankMaterialShell launcher plugin. It reads whatever is on the clipboard,
works out what kind of thing it is, and offers only the actions you wrote for
that kind of thing.

```
copy https://youtube.com/watch?v=…   then   clip   →  your link actions
copy #ff0080                         then   clip   →  your colour actions
copy /home/you/holiday.mkv           then   clip   →  your file actions
copy anything else                   then   clip   →  your text actions
```

Nothing runs on its own. Copying is not a trigger — you open the launcher and
pick an action, or nothing happens.

## Install

Symlink it into the DMS plugin directory:

```sh
ln -s "$PWD/clipboardRunner" ~/.config/DankMaterialShell/plugins/clipboardRunner
```

The shell picks it up on its own (it watches the plugins directory). Enable
**Clipboard Runner** under Settings → Plugins, then add actions under that same
settings panel.

## The four kinds

Every clipboard entry is filed under exactly one of these, so a link never
reaches your text actions:

| Kind | What lands here |
|---|---|
| **Link** | `http://`, `https://`, any other `scheme://`, `mailto:`, `magnet:`, or a bare `www.example.com` |
| **Colour** | `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(…)`, `rgba(…)`, `hsl(…)`, `hsla(…)` |
| **File** | A path starting `/`, `~/`, `./` or `../`, and `file://` URIs (which are decoded to a plain path) |
| **Text** | Everything else |

`file://` counts as a file rather than a link, because what you want to do with
it is almost always a file operation.

## What it ships with

51 actions are written into your list the first time the plugin runs. They are
ordinary entries from that moment on — rename them, retune the filters, delete
the ones you have no use for. The **Restore built-in actions** button in
settings puts back any you removed, and leaves the ones you edited alone.

### Links

| Action | Shown for | Runs |
|---|---|---|
| Open in browser | any link | `xdg-open` |
| Download with aria2c | `http(s)://` | `aria2c` into your downloads folder |
| Open the page source in nvim | `http(s)://` | `curl` to a temp file, then nvim |
| yt-dlp: download video | youtube.com, youtu.be | `yt-dlp` |
| yt-dlp: download audio | youtube.com, youtu.be | `yt-dlp -x --audio-format mp3` |
| sm: install into the music library | youtube.com, youtu.be, deezer.com | `sm music install` |
| sm: install and play | youtube.com, youtu.be, deezer.com | `sm music install`, `mpc update --wait`, queue the newest track and play |
| aria2c: download this magnet | `magnet:` | `aria2c --seed-time=0` |
| Clone into downloads | github.com | `git clone` |
| pm: create a project | github.com | `pm create` |
| gh: fork, then create a project | github.com | `gh repo fork`, then `pm create` on your fork |
| Open the releases page | github.com | `xdg-open <url>/releases` |

### Colours

| Action | Shown for | Runs |
|---|---|---|
| rgb → hex | `rgb(…)` | converts, copies the result, tells you what it was |
| hex → rgb | `#…` | as above |
| hex → hsl | `#…` | as above |
| Save a swatch to downloads | any colour | `magick` writes a 512×512 png |

The three conversions put the result on the clipboard, so you can paste it
straight back where you needed it.

### Files

Every file gets **Open**, **Open the containing folder**, **Open in nvim** and
**Virus scan**. On top of that:

| Group | Actions |
|---|---|
| Audio (`mp3 flac wav m4a aac ogg opus wma aiff alac`) | ffmpeg → mp3, flac, opus, wav |
| Video (`mp4 mkv avi mov webm flv wmv m4v mpg mpeg ts`) | ffmpeg → mp4, mkv, webm, gif; pull the audio out as mp3 |
| Images (`png jpg jpeg webp gif bmp tiff avif heic heif`) | magick → png, jpg, webp, avif, pdf |
| Documents (`doc docx odt ods odp xls xlsx ppt pptx rtf txt md csv`) | libreoffice → pdf |
| Archives (`zip 7z rar tar gz tgz bz2 xz zst lz4 lzma cab arj lzh iso cpio wim deb rpm`) | extract here, extract into downloads, show what is inside |
| Android (`apk xapk apks aab`) | what is this written in; adb install on the connected device |
| AppImage | install it; run it once |
| Folders | compress to zip, 7z or tar.gz beside the folder; open a terminal here |

A conversion never offers itself for a file that is already in that format —
ffmpeg would otherwise be handed the same path as input and output and truncate
the file.

Folders and files are told apart by asking the filesystem, not by guessing from
the name. Every action in the file group carries an **applies to** setting —
*files and folders*, *files only*, or *folders only* — and an action that names
extensions is a statement about files, so it never offers itself for a folder.

**Show what is inside** is the one action that opens a terminal on purpose: an
archive listing is something you read, so it goes to a pager rather than a
notification.

### Copying a file rather than a path

Copying a file in a file manager puts a `file://` URI on the clipboard, which
lands in the file group like any other path.

Copying an **image** — out of a browser, or from a screenshot tool — puts image
data on the clipboard with no file behind it. Rather than skip it, the plugin
writes it into `~/.cache/dms-clipboard-runner/` and treats the result as the
image file it now is, so every conversion in the file group applies. The file is
named after the clipboard entry and reused, so asking twice does not fetch it
twice.

**The result goes back on the clipboard.** When the thing being acted on came
from the cache rather than from disk, whatever the action produced is copied
back when it finishes — that is what you wanted when you copied the image in the
first place, and it means conversions chain: convert, convert again, paste.
Images go back as bytes, so pasting into an editor or a browser works; anything
else (a pdf, say) goes back as a `file://` URI, which is what a file manager
wants. A file that was already on disk is left alone — converting
`~/photos/holiday.png` does not touch your clipboard.

**What is this written in** reads the names inside the package and reports the
framework: Flutter, React Native, Unity, Xamarin/.NET MAUI, Cordova/Ionic, Qt,
Godot, Kotlin, or plain Java/Kotlin when there is no marker. `aapt` and
`apktool` are not needed — the giveaway is which native library got bundled,
and that shows up in the zip listing.

**Install it** (AppImage) copies the file to `~/.local/bin`, makes it
executable, pulls the icon and desktop entry out of the AppImage itself, and
writes them to `~/.local/share/icons` and `~/.local/share/applications` so the
launcher finds it. If extraction fails a minimal entry is written instead, so
the app is still launchable.

### Text

Open in nvim (via a temp file), search the web for it, save it to downloads.

## How things run

Everything runs through **zsh**, detached, with **no terminal**. Anything slow
enough to wonder about carries a **notify** flag and posts a desktop
notification when it finishes, saying whether it worked and the exit code if it
did not. Instant things — open in browser, the colour conversions — have the
flag off, because a notification arriving the moment you pressed Enter is
noise. The flag is a switch on every action, including your own.

The two exceptions that do open a window are the nvim actions, because an
editor cannot run without one. Which terminal they use is a setting.

## Adding actions

Settings → Plugins → Clipboard Runner. Each of the four kinds has its own
section with a **+** button. An action has:

| Field | Required | Notes |
|---|---|---|
| Name | No | What you search for after the trigger. Falls back to the command |
| Icon | No | `material:<name>`, `unicode:<char>`, or a desktop icon theme name |
| Enabled | — | Off hides it from the launcher without deleting it |
| Extensions | No | **File** only. `mp4, mkv, webm` — empty means any extension |
| Filters | No | Zero or more; **all** of them must match. No filters means every entry of that kind matches |
| Command | Yes | Runs via `sh -c`, so pipes, redirects and quoting all work |

Filter operators: `anything`, `includes`, `excludes`, `is exactly`,
`is not exactly`, `starts with`, `ends with`, `matches regex`,
`does not match regex`. They compare against the whole clipboard text and
ignore case unless you turn on the `match_case` button next to the filter.

### Placeholders

| Placeholder | Value |
|---|---|
| `${clipboard}` | The whole clipboard text. `${clipboardContent}`, `${content}` and `${clip}` are the same thing |
| `${type}` | `url`, `color`, `path` or `text` |
| `${path}` | **File** only — the path, with `file://` stripped and percent-escapes decoded |
| `${ext}` | **File** only — lowercase extension, no dot |
| `${basename}` | **File** only — the last path segment |
| `${dirname}` | **File** only — everything before it |
| `${color}` | **Colour** only — short hex expanded to `#rrggbb`, other syntaxes passed through as typed |

Examples:

```
Link   ·  includes "youtube.com"  ·  yt-dlp ${clipboard}
File   ·  mp4, mkv, webm          ·  mpv ${path}
Colour ·  (no filter)             ·  notify-send "Colour" ${color}
Text   ·  excludes "secret"       ·  notify-send "Clipboard" ${clipboard}
```

## Behavior

- The clipboard is read ahead of time — once when the runner is first used, and
  again on each clipboard change (debounced) — because `getItems()` has to
  answer synchronously and the shell has no way for a launcher plugin to say
  "my list changed" after the fact. The instance itself is created lazily, so
  nothing happens until you use the runner at least once.
- Reading uses `clipboard.paste`, which returns the **whole** clipboard, not the
  100-character preview the history list shows. Long links match on their tail
  as well as their head.
- An image-only clipboard, an empty clipboard, or a disconnected DMS each show
  an explanatory row rather than an empty list.
- The row under each action name is the command as it will actually run, with
  the clipboard values filled in and quoted.
- Right-click (or the action panel) offers "Copy the command".
- Edits in the settings panel are picked up on the plugin's `pluginDataChanged`
  signal. If the launcher is already open when you edit, type a character to
  redraw the list — the shell repaints launcher results on query changes only.

## What you need installed

The plugin itself needs nothing beyond the shell. Each action needs its own
tool, and an action whose tool is missing simply fails and — if notify is on —
says so. Status is what was on this machine when the plugin was written.

| Tool | Package (Nixpkgs) | Status here | Needed by |
|---|---|---|---|
| `zsh` | `zsh` | present | every action |
| `notify-send` | `libnotify` | present | every action with notify on |
| `xdg-open` | `xdg-utils` | present | open, containing folder, releases page, web search |
| `python3` | `python3` | present | the three colour conversions, url-encoding the web search |
| `curl` | `curl` | present | open the page source in nvim |
| `nvim` | `neovim` | present | the three open-in-nvim actions |
| `ghostty` | `ghostty` | present | the same three (any terminal will do — it is a setting) |
| `yt-dlp` | `yt-dlp` | present | yt-dlp: download video / audio |
| `aria2c` | `aria2` | present | download with aria2c, magnet download |
| `sm` | your own storage manager | present | sm: install into the music library / install and play |
| `mpc` | `mpc-cli` | present | sm: install and play |
| `git` | `git` | present | clone into downloads |
| `gh` | `gh` | present | gh: fork, then create a project |
| `pm` | your own project manager | present | pm: create a project, and the fork action |
| `ffmpeg` | `ffmpeg` | present | every audio and video conversion |
| `magick` | `imagemagick` | present | every image conversion, image → pdf, colour swatch |
| `unzip` | `unzip` | present | what is this written in |
| `7z` | `p7zip` | present | compress a folder to zip/7z, extract an archive, list an archive |
| `tar` | `gnutar` | present | compress a folder to tar.gz |
| `less` | `less` | present | show what is inside |
| `base64` | `coreutils` | present | writing a copied image out to a file |
| `adb` | `android-tools` | present | adb: install on the connected device |
| `appimage-run` | `appimage-run` | present | run an AppImage once |
| `clamdscan` | `clamav` | present, **daemon not running** | virus scan |
| `soffice` | `libreoffice` | **missing** | libreoffice → pdf |
| `dms` | DankMaterialShell | resolved via `$DMS_EXECUTABLE` | the colour conversions, to put the result back on the clipboard |

Two things are not ready to use as they stand:

- **`soffice` is not installed**, so *libreoffice → pdf* will fail until you add
  `libreoffice` (or `libreoffice-fresh`). The action ships anyway rather than
  being left out, so it works the moment you install it. Images do not need it —
  *magick → pdf* handles those.
- **`clamd` is not running**, so *Virus scan* has nothing to talk to. Start the
  daemon (`services.clamav.daemon.enable = true` on NixOS) and let `freshclam`
  fetch signatures once. Swapping `clamdscan` for `clamscan` in the action works
  without a daemon but is far slower and still needs the signature database.

Deliberately not used, and why: `aapt` and `apktool` would be the obvious way to
read an APK, but the zip listing already answers the only question being asked,
so neither is a dependency. `img2pdf` is unnecessary because `magick` already
converts images to pdf.

## Trust boundary

Commands run exactly as you typed them, and that is the point — this is a
personal command launcher. What is *not* trusted is the clipboard.

Clipboard values never become part of the script text. `yt-dlp ${clipboard}`
is executed as:

```
sh -c 'yt-dlp "$1"' dms-clipboard-action <the clipboard> <path> <ext> …
```

so copying `; rm -rf ~` gives `yt-dlp` a strange argument and nothing more. A
web page cannot put a command on your clipboard and have it run — first because
of the argument passing, and second because you still have to pick the action
yourself.
