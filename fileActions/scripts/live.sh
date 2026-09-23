#!/bin/sh
# What is running right now: every status file in the live state directories.
#
# Run it by hand to see exactly what the plugin sees:
#   sh bin/live.sh            # the default directories
#   sh bin/live.sh /some/dir  # an override, as configured in settings
#
# $XDG_RUNTIME_DIR is resolved HERE rather than in QML, because the shell that
# runs the bar does not necessarily carry it: a compositor started from a
# display manager, or a quickshell relaunched from a stray terminal, can be
# missing it entirely. /run/user/$(id -u) is what it would have been.
set -u

runtime="${XDG_RUNTIME_DIR:-}"
if [ -z "$runtime" ]; then
  runtime="/run/user/$(id -u 2>/dev/null || echo 0)"
fi

if [ "$#" -gt 0 ] && [ -n "${1:-}" ]; then
  set -- "$1"
else
  # Same tool, two names: it was dejavu before it was fct, and which one is
  # installed depends on the generation this machine booted.
  set -- "$runtime/matrix/fct" "$runtime/matrix/dejavu"
fi

# The header is how the plugin reports what it actually looked at, so a wrong
# path is visible in the popout instead of looking like "nothing is running".
printf 'base:%s\n' "$runtime"
for d in "$@"; do
  printf 'watch:%s\n' "$d"
done

# Every header line first, in its own pass. Printing a directory's ok: line
# next to its files would put it directly after the previous directory's last
# file — inside that file's JSON, where it is a parse error and a lost row.
# After this point the output is nothing but file blocks.
for d in "$@"; do
  [ -d "$d" ] && printf 'ok:%s\n' "$d"
done

for d in "$@"; do
  [ -d "$d" ] || continue
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    # Marker, path, then the file. Each file is parsed on its own, so one
    # caught mid-write costs its own row rather than the whole list.
    printf '\n===dejavu===%s\n' "$f"
    cat "$f" 2>/dev/null
    printf '\n'
  done
done
