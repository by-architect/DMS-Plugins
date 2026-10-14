#!/bin/sh
# One speed test, its result as JSON on stdout, from whichever program is
# installed. $1 picks one: auto (the default), ookla, speedtest-cli or
# librespeed. Nothing is installed by this; a missing program is exit 127
# with a sentence on stderr.
#
# "speedtest" is two different programs: Ookla's official CLI, and on many
# systems (NixOS among them) the Python speedtest-cli under a second name.
# Their flags differ, so the program is asked which one it is.
want=${1:-auto}
here=$(cd "$(dirname "$0")" && pwd)

has() { command -v "$1" >/dev/null 2>&1; }
is_ookla() { has speedtest && speedtest --version 2>/dev/null | grep -q Ookla; }
has_sivel() { has speedtest-cli || { has speedtest && ! is_ookla; }; }

ookla() { exec speedtest --format=json --accept-license --accept-gdpr; }
# Where speedtest-cli's own module lives, for nearest.py: next to the
# program (NixOS: <package>/lib/python3.X/site-packages), or nowhere special
# when pip put it where python3 already looks.
sivel_path() {
    for b in speedtest-cli speedtest; do
        p=$(command -v "$b" 2>/dev/null) || continue
        real=$(readlink -f "$p")
        for d in "${real%/bin/*}"/lib/python3*/site-packages; do
            [ -f "$d/speedtest.py" ] && echo "$d" && return 0
        done
    done
    return 0
}

# speedtest-cli's engine against the servers speedtest.net lists as nearest
# (see nearest.py); the plain command only when that engine cannot be
# imported (exit 3). --secure: speedtest.net's own servers over HTTPS, which
# some networks (and captive portals) get in the way of less than HTTP.
sivel() {
    if has python3; then
        mod=$(sivel_path)
        PYTHONPATH="$mod${PYTHONPATH:+:$PYTHONPATH}" python3 "$here/nearest.py"
        code=$?
        [ "$code" = 3 ] || exit "$code"
    fi
    has speedtest-cli && exec speedtest-cli --json --secure
    exec speedtest --json --secure
}
libre() { exec librespeed-cli --json; }

case "$want" in
ookla)
    is_ookla && ookla
    echo "Ookla's speedtest is not installed" >&2
    exit 127
    ;;
speedtest-cli)
    has_sivel && sivel
    echo "speedtest-cli is not installed" >&2
    exit 127
    ;;
librespeed)
    has librespeed-cli && libre
    echo "librespeed-cli is not installed" >&2
    exit 127
    ;;
esac

is_ookla && ookla
has_sivel && sivel
has librespeed-cli && libre
echo "No speed test program found: install speedtest-cli, Ookla's speedtest or librespeed-cli" >&2
exit 127
