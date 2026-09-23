# Mount Manager

Every disk in the bar, with the two buttons that matter: mount it, or unmount
it before pulling it out. No root — `udisks` and polkit already allow a
logged-in user to do this to their own removable media.

```
   bar:   [ ⛁ ]          nothing removable attached
          [ ⇄ 1/2 ]      two removable volumes, one of them mounted

   click:
        ┌──────────────────────────────────────────────────────────┐
        │  Disks                                          ⟳    ⨯   │
        │  3 mounted · 2 removable                                 │
        │                                                          │
        │  Removable                                               │
        │  (⇄)  backup                        [📂] [⧉] [⏏] [⏻]     │
        │       /run/media/neo/backup                              │
        │       466 GB · ext4 · 76% used                           │
        │       ███████████████████████░░░░░░░                     │
        │  (⇄)  windows                             [▸] [⏻]        │
        │       not mounted                                        │
        │       466 GB · ntfs                                      │
        │                                                          │
        │  Internal                                                │
        │  (⛁)  EFI                                 [📂] [⧉]       │
        │       /boot                                              │
        │       1.0 GB · vfat · 30% used · system                  │
        │  (🔓)  root                               [📂] [⧉]       │
        │       /  ·  /nix/store                                   │
        │       936 GB · ext4 · 41% used · system                  │
        └──────────────────────────────────────────────────────────┘
```

Buttons, left to right: open the mount point, copy its path, mount, unmount,
and power the whole disk off.

## What it lists

One row per thing that holds — or could hold — a filesystem. Partitions,
unlocked containers, and whole disks formatted without a partition table (which
is every USB stick sold pre-formatted). A disk that merely contains partitions
is not a row of its own; its partitions are.

Two kinds of row are deliberately *not* what lsblk would print:

**An unlocked LUKS container gets no row.** It would say "crypto_LUKS, not
mounted" forever, directly above the row holding the filesystem it was
protecting. The child is the answer; the container is plumbing. A **locked** one
does get a row, because "there is 17 GB here and it is locked" is worth seeing.

**A mapper device is named after its partition.** `luks-e1fa9073-5d47-…` names
nothing; the partition it came from is usually labelled `root`, so that is what
the row says.

Loop devices — snap and AppImage mounts, anything mounted from a file — are
hidden unless you turn them on in settings.

## What it will not do

**System mounts have no unmount button.** Not a disabled one, not one that
fails: none. A mount is treated as part of the running system when it is not
removable and not under `/run/media`, `/media` or `/mnt` — so `/`, `/nix/store`
and `/boot` are listed with their usage, marked `system`, and left alone.

**Locked volumes are not unlocked here.** No passphrase passes through the bar.
A locked row shows the one command that unlocks it, with a button to copy it:

```sh
udisksctl unlock -b /dev/nvme0n1p3
```

**Eject means eject.** The power button unmounts every filesystem on the disk
and then powers it off, because that is what "I want to pull this out" means. A
partition that was already unmounted is not an error; only the power-off
decides the outcome.

## What it shows

| | |
|---|---|
| Where it is mounted | every mount point, shortest first — a filesystem mounted at both `/` and `/nix/store` leads with `/` |
| How full it is | a bar that turns amber past 75% and red past 90%, because a nearly-full disk is worth noticing without reading the number |
| What it is | size, filesystem type, and `read-only` when it is |
| What it is doing | `mounting…` / `unmounting…` / `ejecting…` with a spinner, and the row refuses a second instruction while it works |

Sizes are computed from bytes rather than taken from `lsblk`'s own formatting,
which follows the locale — `936,3G` on a `tr_TR` system.

## When something fails

udisks' own sentence is shown, not an exit code:

> Could not unmount backup — Error unmounting /dev/sdb1:
> GDBus.Error:org.freedesktop.UDisks2.Error.DeviceBusy: Target is busy

That is the difference between "it did not work" and "close the file manager
window that is sitting in that directory".

## Seeing what it sees

Both readers are plain shell scripts:

```sh
sh scripts/list.sh                   # every block device, as JSON
sh scripts/action.sh mount /dev/sdb1 # status:ok / status:err, then the message
```

`action.sh` always exits 0 and always states the outcome on its first line, so
the reader never has to race an exit code against the output it belongs to.

From the running shell:

```sh
dms ipc call mountManager status     # every row, as the plugin sees it
dms ipc call mountManager refresh
```

## Settings

| Setting | Default | |
|---|---|---|
| React to plugging in | on | watch udev so a device appears the moment it is plugged in |
| Hide when nothing is removable | off | take the pill out of the bar while no removable device is attached |
| Show loop devices | off | include snap/AppImage and file-backed mounts |
| Re-read devices | 5000 ms | the backstop poll; the list is also re-read after every action and on every udev event |

## Needs

`lsblk` (util-linux) and `udisksctl` (udisks2), both of which a desktop system
already has. Mounting works without root through polkit; a system with a polkit
policy that forbids it will say so in the failure message rather than silently
doing nothing.

## Shape

`mounts.js` holds the flattening, the classification and the action rules as
pure functions over `lsblk -b -J` output, so they run and are tested outside
quickshell. The QML above them is layout.

One reader for the whole shell: `MountService` is a singleton, so the bar pill
on every screen and the popout all read the same rows. Two triggers, because
neither alone is right — a `udevadm monitor` stream so a stick plugged in
appears at once, debounced because one plug-in emits a burst of events, and a
slow poll so a missed event costs seconds rather than forever.
