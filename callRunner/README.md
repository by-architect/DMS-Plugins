# Call Runner

Call people from the launcher, on your phone. Type `call ` and a name or a
number: the phone's own contacts and newest calls are listed, and the one you
pick is rung **from the phone itself** — you talk on the phone (or its
headset), the desktop only dials.

```
call                       nothing typed: the people called last, then everybody
  ↙ Ada                    missed 2 h ago  ·  mobile  ·  +905551234567
  ↗ Şükrü Işık             outgoing 5 h ago  ·  mobile  ·  +905551112233
  ↘ +905559990000          incoming 6 h ago  ·  +905559990000
  ★ Katherine              mobile  ·  +905554445566
  👤 Ali Yılmaz             other  ·  +905552223344

call sukru                 a name: without accents, ı as i, each word a start
  ★ Şükrü Işık             mobile  ·  +905551112233  ·  outgoing 5 h ago

call 0555 222 33 44        a number: called as typed, and whoever has it
  ⌗ Call 05552223344       Ali Yılmaz  ·  other
  👤 Ali Yılmaz             other  ·  +905552223344

call hang up               ends the call the phone is in ("hang" is enough)
call refresh               reads the contacts again now
```

Enter calls the row. A toast says it is calling, and another one if the phone
did not start the call — most often because its dialer asks which SIM to use.

## How it reaches the phone

The phone is a host from **SSH Hosts** (sshManager), with key auth — the same
one Phone Status uses, unless another is picked here. `scripts/phone.sh` goes
in as ssh's stdin and runs under `sh -s`, as root through `su`, so nothing is
installed on the phone:

| | |
|---|---|
| Contacts | `content query --uri content://com.android.contacts/data/phones`: each person's numbers, their kind (mobile, work…) and whether they are starred. A number saved in two accounts is one row |
| Newest calls | `content query --uri content://call_log/calls`, the newest 60 |
| Calling | `am start -a android.intent.action.CALL -d tel:<number>` — what the dialer does when you press call. Then the call state (`dumpsys telephony.registry`) is watched for four seconds, to tell whether it started |
| Hanging up | `input keyevent KEYCODE_ENDCALL`, only while the phone is in a call: with none, that key turns the screen off |

When ssh cannot reach the phone at all, **adb** is tried instead, over a USB
cable — only the device whose serial is the phone's own (`ro.serialno`,
learned the first time ssh worked), or the one named in the settings. adb is
looked for on `PATH`, then under `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`,
`~/Android/Sdk` and `~/Opt/Android/Sdk`.

The contacts are kept in the plugin's state
(`~/.local/state/DankMaterialShell/plugins/callRunner_state.json`), so the
list is there at once, even after a restart. Opening the launcher reads them
again in the background when they are older than the setting (15 minutes);
the list changes in place when they arrive. Reading them takes about five
seconds and some 15 KB.

```sh
ssh -p 2422 user@phone sh -s contacts < scripts/phone.sh     # see it by hand
ssh -p 2422 user@phone sh -s call '+905551234567' < scripts/phone.sh
```

## Setting up

1. The phone in **SSH Hosts** with a key, connected once from there to accept
   its host key — Phone Status's setup is the same.
2. Root (`su`) for the sshd's user on the phone: Android lets only root, or an
   app with the permission, read the contacts and the call log.
3. Pick the phone under **Settings → Plugins → Call Runner** (or leave it on
   Phone Status's phone).

## Settings

| Setting | Default | |
|---|---|---|
| Trigger | `call ` | |
| Phone | Phone Status's phone | an SSH Hosts host |
| adb serial | learned over ssh | the only device adb may call through |
| Read the contacts again after | 15 min | |
| Newest calls shown | 8 | with nothing typed |
| Results shown | 40 | |

## Implementation notes

- `content` is a Java program, started by `app_process`, and it needs
  Android's own environment — `BOOTCLASSPATH`, and `ANDROID_I18N_ROOT` for
  ICU. An sshd on the phone (Nixup's, Termux's) starts without it, and then
  `content` prints nothing at all, not even an error, and `sqlite3` aborts.
  The script takes that environment from zygote's (`/proc/<zygote>/environ`).
- The launcher's `getItems()` must answer at once, so it answers from the
  kept contacts and asks again (`requestLauncherUpdate`) when a read ends.
- Matching is done here, not by the launcher: rows carry `_preScored` so a
  match on a number, or who was called last, keeps its place.
- A number only ever reaches the phone as digits, `+`, `*` and `#`
  (`contacts.js` `dialable()`), and `phone.sh` refuses anything else before
  it runs a thing.

## Tests

```sh
qmltestrunner -input tests/tst_contacts.qml
```

`contacts.js` holds the parsing and the matching, tested on an answer shaped
on a real run on an Android 16 phone. `scripts/test-plugin-all.sh` in the
project runs it with the rest.
