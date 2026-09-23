#!/bin/sh
# Mount, unmount or eject one device, through udisks so no root is needed —
# polkit already lets a logged-in user do this to their own removable media.
#
#   sh scripts/action.sh mount   /dev/sdb1
#   sh scripts/action.sh unmount /dev/sdb1
#   sh scripts/action.sh eject   /dev/sdb      (whole disk)
#
# Always exits 0 and always says how it went on its first line, so the reader
# never has to race an exit code against the output it belongs to:
#
#   status:ok      Mounted /dev/sdb1 at /run/media/neo/USB DISK
#   status:err     Error mounting /dev/sdb1: … NotAuthorized …
#
# udisks' own sentences are kept verbatim: "Object … is not mounted" tells you
# what happened, and an exit code does not.
set -u

verb="${1:-}"
target="${2:-}"

report() {
  if [ "$1" = 0 ]; then
    printf 'status:ok\n%s\n' "$2"
  else
    printf 'status:err\n%s\n' "$2"
  fi
  exit 0
}

if [ -z "$verb" ] || [ -z "$target" ]; then
  report 1 "usage: action.sh <mount|unmount|eject> <device>"
fi

case "$verb" in
  mount)
    out=$(udisksctl mount -b "$target" --no-user-interaction 2>&1)
    report "$?" "$out"
    ;;
  unmount)
    out=$(udisksctl unmount -b "$target" --no-user-interaction 2>&1)
    report "$?" "$out"
    ;;
  eject)
    # Power-off refuses while anything on the disk is still mounted, and the
    # point of the button is "I want to pull this out", so every filesystem on
    # it is unmounted first. A partition that was already unmounted is not a
    # failure; only the power-off decides the outcome.
    for part in $(lsblk -nro PATH "$target" 2>/dev/null); do
      [ "$part" = "$target" ] && continue
      udisksctl unmount -b "$part" --no-user-interaction >/dev/null 2>&1 || true
    done
    udisksctl unmount -b "$target" --no-user-interaction >/dev/null 2>&1 || true
    out=$(udisksctl power-off -b "$target" --no-user-interaction 2>&1)
    report "$?" "$out"
    ;;
  *)
    report 1 "unknown action: $verb"
    ;;
esac
