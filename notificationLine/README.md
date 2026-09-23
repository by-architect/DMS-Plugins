# Notification Line

Notifications as chat lines instead of cards. One notification is one line,
lines stack in a screen corner, and the stack scrolls itself out of the way as
each line expires — the shape Minecraft's chat overlay has.

It replaces DankMaterialShell's own notification popups, but not its
notification *system*: the plugin never talks to D-Bus. It draws
`NotificationService.visibleNotifications`, so everything configured under
**Settings → Notifications** — per-urgency timeouts, per-app rules, dedupe, Do
Not Disturb, history, the notification centre — keeps working untouched.

## The line

```
 4m  [] discord    Someone   →  are you coming to the thing tonight or …  ⌄
 └┬┘  └┬┘  └──┬──┘   └──┬──┘       └──────────────┬──────────────┘       └┬┘
 age  icon  app      title                      body                   unfold
```

| Part | Colour |
|---|---|
| age | dimmed, `now` → `4m` → `2h` → `3d` |
| icon | the notification's own image, else the app icon, else its initial |
| app name | accent (`Theme.primary`; `Theme.error` when urgency is critical) |
| title | `Theme.surfaceText`, medium weight |
| body | `Theme.surfaceVariantText`, after a `→` |

## Width

A line is only as wide as its text. It grows until it would pass the maximum
width — **half the screen** by default, adjustable per screen percentage — and
then stops: the title and body are elided with `…` and a `⌄` appears at the
right edge. Everything that fits stays on exactly one line.

Clicking the `⌄` (or right-clicking the line) unfolds that line in place: it
widens to the full maximum, the body re-flows over several wrapped lines, and
any actions the notification carries appear as chips underneath. Unfolding also
stops the expiry timer, so a long notification does not vanish while it is
being read. `⌃` folds it back and the timer restarts.

## Mouse

| | |
|---|---|
| hover | pauses the expiry timer |
| left click | invokes the notification's default action, if it has one; otherwise just clears the line |
| right click | unfold / fold |
| middle click | dismiss for real (also clears it from the notification centre) |
| `⌄` / `⌃` | unfold / fold |

A line that is only cleared (left click without an action, or expiry) stays in
the notification centre — same as swiping away a shipped popup.

## How long a line stays

DMS's own timer honours whatever `expire_timeout` the sending app asked for,
and only falls back to **Settings → Notifications** when the app passes `-1`.
That is why notifications from different apps live for wildly different
lengths of time on the same stack. The plugin therefore runs the clock itself
by default:

| Setting | Effect |
|---|---|
| **Ignore app-supplied timeouts** (on) | every line uses your per-urgency timeout from Settings → Notifications, whatever the app asked for |
| **Line lifetime** `0` | follow those per-urgency timeouts |
| **Line lifetime** `N` | one flat duration for every line, whatever its urgency |

Turning the toggle off and leaving the lifetime at `0` hands timing straight
back to the shell, app timeouts included.

A per-urgency timeout of `0` — which is the default for critical — still means
*never expires*, under either mode.

The clock lives in the daemon, not in the line, because the rows are recycled
as the stack changes and a timer inside a row would restart every countdown
every time another notification arrived. Hovering or unfolding a line holds it;
letting go gives it its full time back.

## Replacing the built-in popups

**Settings → Plugins → Notification Line → Replace the built-in popups**, on by
default.

DMS has no "off" switch for its notification cards: the monitor list under
**Settings → Displays → Notifications** treats an empty selection as *every*
screen, so there is no way to select none. The plugin therefore writes a screen
name that cannot exist — `notificationLine-suppressed` — into
`screenPreferences.notifications`, which makes the shell's popup manager match
zero screens. It also clears `notificationFocusedMonitor`, which would
otherwise bypass that filter entirely.

Both previous values are saved into the plugin's own settings first and put
back when the toggle goes off, when the plugin is disabled, or when it is
removed. If the shell is ever killed mid-suppression and the setting is stuck,
it is a plain edit in `~/.config/DankMaterialShell/settings.json`:

```json
"screenPreferences": { "notifications": ["all"] }
```

Leaving the toggle off gives you both at once — the lines and the cards — which
is only useful for comparing them.

## Stack depth

`NotificationService` allows four popups at a time and, past that, **evicts
the oldest on the spot** — no timeout involved. That is what made a burst
collapse to a handful of lines the instant it landed while the survivors kept
their configured time.

So the shell's limit is deliberately not the number of lines drawn. The plugin
raises it well clear of **Lines on screen** and does its own trimming instead:
a notification past the visible count is *hidden, not killed*, keeps its full
lifetime, and takes its place on the stack when one of the visible lines
expires. Nothing is ever retired early by arriving in company.

The trade-off is that on a very busy stack an older notification can surface a
little after it arrived. Shorten the lifetime if you would rather a burst
drained faster.

Bottom corners stack upwards with the newest line at the bottom; top corners
hang downwards with the newest at the top.

## Settings

| Setting | Default | |
|---|---|---|
| Corner | bottom right | six positions, including bottom/top centre |
| Monitors | all | or only the screen focused when the notification arrived |
| Side / top margin | 12 px | gap from the anchored edges |
| Lines on screen | 6 | 1–12 |
| Maximum width | 50 % | share of the screen a line may reach |
| Expanded height | 8 | wrapped text lines when unfolded |
| Line spacing | 3 px | |
| Text size | 13 px | |
| Background opacity | 72 % | drop it for the translucent overlay look |
| Ignore app-supplied timeouts | on | use your own timeouts instead of the app's |
| Line lifetime | 0 s | one flat duration for every line; 0 follows the per-urgency timeouts |
| Show age / icon / app name | on | each part of the line can be dropped |
| Replace the built-in popups | on | see above |

## IPC and keybinds

The plugin registers no keybinds of its own — bind these in your compositor
config, the same way the other panel plugins are bound.

```sh
dms ipc call notificationLine dismiss        # clear the newest line, one per press
dms ipc call notificationLine dismissOldest  # clear the oldest line instead
dms ipc call notificationLine clear          # clear every line on screen
dms ipc call notificationLine clearAll       # clear the lines *and* the notification centre
dms ipc call notificationLine recall         # put the most recent hidden notification back on the stack
dms ipc call notificationLine test           # send a test notification
dms ipc call notificationLine suppress off   # put the built-in popups back
dms ipc call notificationLine status         # position, line count, timing mode, suppression
```

`dismiss` and `recall` are inverses: hold the dismiss key to walk the stack
down one line at a time, hold the recall key to walk back up through the
notification centre. `clear` leaves everything in the notification centre;
`clearAll` is the destructive one.

Niri, as an example:

```kdl
binds {
    Mod+Shift+N       { spawn "dms" "ipc" "call" "notificationLine" "dismiss"; }
    Mod+Shift+Ctrl+N  { spawn "dms" "ipc" "call" "notificationLine" "clear"; }
    Mod+Shift+R       { spawn "dms" "ipc" "call" "notificationLine" "recall"; }
}
```

Without the `dms` CLI on your PATH, every call has the longer equivalent:

```sh
SHELL_PATH=$(quickshell list --all | grep -oE '/[^ ]*/shell\.qml' | head -1)
quickshell -p "$SHELL_PATH" ipc call notificationLine dismiss
```

## Install

```sh
ln -sfn "$PWD/notificationLine" ~/.config/DankMaterialShell/plugins/notificationLine
```

Then enable it in **Settings → Plugins**.

## Notes

- The window for each stack is always the full maximum width, so lines of
  different lengths do not make it resize under the cursor. Its input region is
  masked to the drawn plates only, so the empty track beside a short line stays
  click-through.
- Rows are indexed rather than bound to the notification list directly: a JS
  array model resets the whole repeater on every change, which would tear down
  and rebuild every line — replaying its entrance animation — each time any
  other notification arrived or expired.
- The stack is capped to the screen height, with the column pinned to the
  anchored edge, so the overflow is always the oldest lines rather than
  whichever end the compositor decides to clamp.
- Lines animate in; they disappear without an exit animation, because a line is
  destroyed the moment `NotificationService` drops it from
  `visibleNotifications` and holding a copy back just to fade it out would mean
  the plugin and the service disagreeing about what is on screen.
