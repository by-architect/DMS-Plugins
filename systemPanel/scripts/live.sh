#!/bin/sh
# What is running right now: every status file in the live state directory.
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
  # fct is the name now; dejavu is what it was called before the rename, and
  # is only reached if an older generation is what booted. First one that
  # exists wins rather than both at once — the same rule history.sh uses for
  # the event log, and one live directory is the whole truth anyway.
  set -- "$runtime/matrix/fct" "$runtime/matrix/dejavu"
fi

# The header is how the plugin reports what it actually looked at, so a wrong
# path is visible in the popout instead of looking like "nothing is running".
printf 'base:%s\n' "$runtime"
for d in "$@"; do
  printf 'watch:%s\n' "$d"
done

live=""
for d in "$@"; do
  if [ -d "$d" ]; then
    live="$d"
    break
  fi
done

[ -n "$live" ] || exit 0
printf 'ok:%s\n' "$live"

# Every header line is printed before this point, never between files: a header
# line emitted after a file block lands inside that file's JSON, where it is a
# parse error and a silently lost row. From here on the output is file blocks
# and nothing else.
for f in "$live"/*.json; do
  [ -f "$f" ] || continue
  # Marker, path, then the file. Each file is parsed on its own, so one caught
  # mid-write costs its own row rather than the whole list. The marker's
  # wording is historical; it is just a separator between this script and the
  # parser that reads it.
  printf '\n===dejavu===%s\n' "$f"
  cat "$f" 2>/dev/null
  printf '\n'
done
