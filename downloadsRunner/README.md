# Downloads (downloadsRunner)

A DankMaterialShell launcher plugin: find something in your downloads folder
and put its full path on the clipboard.

```
dl                 →  the newest downloads first
dl invoice march   →  every word has to appear in the path: Invoices/2026-march.pdf
dl .pdf            →  every pdf
Enter              →  copies /home/you/Downloads/Invoices/2026-march.pdf
```

Right-click a result (or open the action panel) for the rest:

| Action | Does |
|---|---|
| **Copy path** | the default, also on Enter — the full path as text |
| Copy as a file | a `file://` link as `text/uri-list`: paste it into a file manager to copy the file, or into a chat to attach it |
| Copy name | just the file name |
| Open | `xdg-open` |
| Show in folder | the file manager's own D-Bus call, which opens the folder with the file selected; plain `xdg-open` on the folder if there is none |

Each row says where the file sits (when it is in a folder inside Downloads),
its size and how long ago it changed. Pictures show a thumbnail. A download
still in progress (`.part`, `.crdownload`, …) says so.

## How it searches

The folder is listed with one `find` — newest first, three folders deep, hidden
files left out — and the list is kept: the launcher asks for results on every
keystroke and has to get them at once. A list older than three seconds is
redone in the background and the results updated when it lands, so something
that finished downloading a moment ago is there by the time you type its name.

Every word of the query has to appear somewhere in the path below the folder.
Order: the whole query in the file's own name first (best at its start), then
files whose name holds more of the words, then shallower ones, then newest.

A name with a newline in it is skipped — the listing is one file a line, and
such a name would come back as a wrong path.

Like every launcher plugin, it also answers plain searches typed without the
trigger, unless switched off under **Settings → Launcher → Plugin visibility**.
That costs nothing here beyond the kept list.

## Settings

| Setting | Default | |
|---|---|---|
| Trigger | `dl ` | the trailing space keeps unrelated words from matching |
| Folder | `~/Downloads` | any folder; `~` is understood |
| Folders deep | 3 | 1 is the folder itself only |
| Results shown | 30 | with nothing typed, the newest |
| Include hidden files | off | names starting with a dot |

## Install

```sh
ln -sfn "$PWD/downloadsRunner" ~/.config/DankMaterialShell/plugins/downloadsRunner
dms ipc call plugin-scan scan
dms ipc call plugins enable downloadsRunner
```

Needs `find` (findutils), `sort` and `head` (coreutils) — all GNU, for
`find -printf`.

## Tests

```sh
node tests/files.test.js              # matching, parsing, the listing script itself
node tests/files.test.js ~/Downloads  # and list a real folder the same way
```
