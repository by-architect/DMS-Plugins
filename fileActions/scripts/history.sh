#!/bin/sh
# How past actions went. The live directory cannot answer this: a wrapper
# deletes its status file on every exit path, including a kill. The event log
# is the only record, and it comes in two places holding the same fields.
#
#   sh bin/history.sh [max-records]
set -u

n="${1:-600}"
case "$n" in
  ''|*[!0-9]*) n=600 ;;
esac

home="${HOME:-}"
if [ -z "$home" ]; then
  home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
fi

for f in "$home/.local/state/fct.json" "$home/.local/state/dejavu.json"; do
  if [ -r "$f" ]; then
    printf 'source:%s\n' "$f"
    tail -n "$n" "$f"
    exit 0
  fi
done

# No readable state file: the same records also go to the journal, as MATRIX_*
# fields on each entry.
printf 'source:journal\n'
journalctl -o json --no-pager --since '-14 days' -n "$n" -t matrix-fct -t matrix-dejavu 2>/dev/null
