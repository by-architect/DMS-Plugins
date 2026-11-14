# Quick Notes

Jot a task down without waiting for anything: a keybind opens a card with a
field at the bottom and your tasks as lines above it, newest nearest to the
field. The tasks are a Nextcloud Tasks list — `main` unless you pick another —
kept in step in the background.

```
┌────────────────────────────────────────────────────────────┐
│ ✎ Quick Notes  main · 3 open                    ⟳   ✕      │
│   Synced 2 min ago                                         │
│                                                            │
│   ○ call the bank                                    3d    │
│     about the card renewal                                 │
│   ◉ buy milk  (done: struck through, dimmed)         1h    │
│ ┌────────────────────────────────────────────────────────┐ │
│ │ ○ dentist, Thursday                           ☁   now  │ │  ← selected (Ctrl+K)
│ └────────────────────────────────────────────────────────┘ │
│ ┌────────────────────────────────────────────────────────┐ │
│ │ + A new task — Enter saves it, / searches              │ │
│ └────────────────────────────────────────────────────────┘ │
│  Enter save · Shift+Enter new line · Ctrl+J/K move · …     │
└────────────────────────────────────────────────────────────┘
```

## Opening it

Bind the IPC call to a key under **Settings → Keybinds → Add → Spawn**:

```sh
dms ipc call quickNotes toggle
```

Esc closes it, and so does a click outside the card. Whatever you had typed
and not saved is still in the field next time — a search is not.

## Keys

The field has the keyboard the whole time, so typing always types. The
selected task is a highlight you move with Ctrl+J/K; Ctrl+Enter and
Ctrl+Delete act on it.

| Key | Does |
|---|---|
| `Enter` | save what is typed as a new task |
| `Shift+Enter` | a new line: the first line is the task's title, the rest its notes |
| `Ctrl+K` / `Ctrl+J` | move the selection up / down; down from the bottom task is back to the field |
| `↑` / `↓` | the same, while the field is empty |
| `Ctrl+Enter` | mark the selected task done, or not done again |
| `Ctrl+Delete` | delete the selected task (with nothing selected, it is the field's own delete-next-word) |
| `Ctrl+Z` | while "Deleted … — Ctrl+Z brings it back" shows (8 seconds), bring the deleted task back; otherwise the field's own undo |
| `/` | start a search: text beginning with `/` filters the tasks instead of being a task |
| `Enter`, while searching | back to the whole list with what you found still selected, the way Enter ends a search in vim |
| `Ctrl+R` | sync now (also tries again a change the server refused) |
| `Esc` | leave the search, then drop the selection, then close |

Clicking works too: a task's circle marks it done, the ✕ that shows on hover
deletes it, and clicking a task selects it.

A search looks for every word you type in the title and the notes, ignoring
capitals and accents — `istanbul` finds "İstanbul", `cay` finds "çay" — and it
looks through every task, done ones from long ago too. The best match is
selected as you type, so `/dentist` then `Ctrl+Enter` marks it done.

## Nothing waits on the network

- **Opening** shows the list as it was at the last sync, straight from the
  plugin's state file. Opening the window never starts a sync.
- **The list is read** in the background: shortly after the shell starts, then
  every 5 minutes (a setting), and when you press `Ctrl+R`. When nothing in the
  list has changed, that costs one small request: the list's ctag is compared
  and nothing more is fetched.
- **Every change you make** — a new task, done, not done, deleted — is in the
  list at once and sent on its own a moment later. A task waiting to reach the
  server has a small ☁ next to it.
- **Offline**, changes wait in a queue, which survives a restart, and are sent
  when the server answers again: retried after 15 s, 30 s, 1 min, … up to the
  sync interval, and at once when the network comes back.
- **A delete** is sent 8 seconds after you make it, so `Ctrl+Z` can still take
  it back.

Several changes to the same task before it is sent are merged: a task typed
and marked done goes up as one task already done; one typed and deleted never
goes up at all.

### When someone else changed it too

Marking a task done changes three properties — `STATUS`, `COMPLETED` and
`PERCENT-COMPLETE`, as Nextcloud Tasks writes them — and the timestamps.
Everything else in the task (its due date, alarms, categories, subtask link,
properties some other app added) goes back exactly as it came.

The change is sent with `If-Match` on the ETag it was read with. If the task
was edited elsewhere in the meantime — renamed on your phone, say — the server
refuses it with 412; the task is read again and marked on top of the new
version, so neither change is lost.

A change the server refuses for good (a list shared with you read-only, for
instance) is marked in red with the server's reason and stops holding up the
rest; `Ctrl+R` tries it again.

## Setting it up

Under **Settings → Plugins → Quick Notes**:

| Setting | |
|---|---|
| Nextcloud address | `https://cloud.example.com` — or the link of one list (Tasks or Calendar → … → Copy private link), which then is the list, whatever its name |
| User name | your Nextcloud login |
| App password | make one under Nextcloud's **Personal settings → Security → Devices & sessions → Create new app password** |
| Password file | instead of the app password above: a file holding it, such as an agenix or sops-nix secret; read again whenever it changes |
| Task list | the list's name, `main` by default; capitals do not matter, and the list's address name works too |
| Read the list every | 1–60 minutes, 5 by default |
| Keep done tasks in the list | for an hour, a day (default), a week, always, or not at all — a task you mark stays until the window closes either way |

The list is found the way CalDAV clients find one: from the address, through
Nextcloud's `remote.php/dav` (also under a subfolder install), your account,
and your calendars, to the one with that name that can hold tasks. When there
is none, the status line says so and names the lists there are. This plugin
does not make lists: make `main` in Nextcloud Tasks first.

Any other CalDAV server works the same way — Radicale, for one, is what the
tests run against. A server that does not send task data in a PROPFIND (Nextcloud
does) gets one GET per changed task instead.

A wrong password is not retried on the timer: Nextcloud throttles an address
that keeps failing to log in. It is tried again when you change the settings or
the password, or press `Ctrl+R`.

Until it is set up the list works on its own, kept on this machine; what you
add goes up once it is.

## Where your data lives

| What | Where | |
|---|---|---|
| Settings | `~/.config/DankMaterialShell/plugin_settings.json` | the address, user name, list and timings — no password |
| App password | `~/.local/share/DankMaterialShell/plugins/quickNotes/secrets.json` | created mode 0600 (written under `umask 077`, so never readable by anyone else even for a moment); never shown in the settings again |
| The list and the queue | `~/.local/state/DankMaterialShell/plugins/quickNotes_state.json` | what was last read from the server and what has not been sent yet |

The password is kept out of the settings file because that file sits next to
every other plugin's settings — and on a system that manages it with
home-manager it ends up in the Nix store, readable by every user. For the same
reason, put the password in a password file rather than in your Nix config.

Requests go through Qt's own XMLHttpRequest inside the shell, so nothing needs
installing and the password travels in an HTTP header, never on a command line
where `ps` would show it.

## IPC

```sh
dms ipc call quickNotes toggle            # also: open, close
dms ipc call quickNotes add "buy milk"    # add a task without opening anything; \n starts its notes
dms ipc call quickNotes list              # the open tasks, oldest first
dms ipc call quickNotes sync              # sync now
dms ipc call quickNotes status            # server, list, counts, queue, last sync and error, window focus
```

## What it does not do

It writes titles, notes and done-ness. It does not edit a task's text, set due
dates or priorities, or make subtasks — do that in Nextcloud Tasks. Subtasks
made there are shown, indented under their parent. A repeating task is marked
done as a whole.

## Tests

```sh
node tests/quicknotes.test.js          # iCalendar, WebDAV XML, the list's order and search,
                                       # the sync engine against an in-memory Nextcloud,
                                       # and the window's keys pressed for real under qmltestrunner
node tests/quicknotes.test.js --live   # plus the sync against a real CalDAV server (Radicale,
                                       # started on 127.0.0.1 and removed after), over node's
                                       # http and over Qt's XMLHttpRequest
```

`scripts/test-plugin-all.sh` in the project runs the first, and
`scripts/test-plugin-caldav.sh` the second. The window tests and the
XMLHttpRequest run use the qmltestrunner of the Qt quickshell is built on, and
are skipped where there is none.
