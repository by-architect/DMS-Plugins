#!/bin/sh
# Every block device as JSON, sizes in bytes so the formatting is ours and not
# the locale's ("936,3G" is what a tr_TR lsblk prints otherwise).
#
# Run it by hand to see exactly what the plugin sees:
#   sh scripts/list.sh
set -u

COLUMNS_NEW='NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS,FSAVAIL,FSUSED,FSSIZE,FSUSE%,RM,HOTPLUG,RO,TRAN,MODEL,PKNAME'
# util-linux before 2.37 has no MOUNTPOINTS (plural) and no PATH; the parser
# reads the singular column and rebuilds the path from the name.
COLUMNS_OLD='NAME,TYPE,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT,FSAVAIL,FSUSED,FSSIZE,FSUSE%,RM,RO,TRAN,MODEL,PKNAME'

if out=$(lsblk -b -J -o "$COLUMNS_NEW" 2>/dev/null) && [ -n "$out" ]; then
  printf '%s\n' "$out"
  exit 0
fi

lsblk -b -J -o "$COLUMNS_OLD" 2>/dev/null
