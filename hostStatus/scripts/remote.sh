# Host Status probe. This runs on the REMOTE host: ssh starts `sh -s` there
# and this file is its stdin, so nothing has to be installed on the far end --
# only a POSIX sh, plus /proc (Linux) for anything beyond storage.
#
# Every line it prints starts with "hs:", so whatever a login file echoes on
# the way in (a chatty .bashrc, a forced command's banner) is skipped by the
# reader, and hs:begin / hs:end tell "answered" apart from "connected, but
# this never ran". Values are printed raw; the arithmetic is done locally, in
# hosts.js, where it is tested.
export LC_ALL=C
echo "hs:begin 1"
echo "hs:os $(uname -s 2>/dev/null)"

# Two samples a second apart: CPU usage is a rate, one sample says nothing.
if [ -r /proc/stat ]; then
    a=$(grep '^cpu ' /proc/stat)
    sleep 1
    b=$(grep '^cpu ' /proc/stat)
    echo "hs:cpu $a"
    echo "hs:cpu $b"
    echo "hs:ncpu $(grep -c '^cpu[0-9]' /proc/stat)"
fi

if [ -r /proc/meminfo ]; then
    grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo | sed 's/^/hs:mem /'
fi
[ -r /proc/uptime ] && echo "hs:uptime $(cat /proc/uptime)"
[ -r /proc/loadavg ] && echo "hs:load $(cat /proc/loadavg)"

# Filesystem types, so tmpfs, overlay and friends can be told from disks.
[ -r /proc/mounts ] && sed 's/^/hs:mnt /' /proc/mounts

# A dead network mount makes df hang for good, so it gets five seconds when
# the far end has a timeout(1) that takes this syntax (old busybox does not).
t=""
timeout 1 true >/dev/null 2>&1 && t="timeout 5"
$t df -P -k 2>/dev/null | sed -e '1d' -e 's/^/hs:df /'

echo "hs:end"
