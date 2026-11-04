# What phoneStatus reads off the phone, in one go.
#
# Sent as ssh's stdin and run by `sh -s` on the phone (Termux, or anything
# with a POSIX sh), so nothing is installed there. Every line it prints that
# matters starts with "ps:"; phone.js does the reading. Anything else -- a
# login banner, a message from the shell -- is ignored.
#
#   sh -s          the regular check
#   sh -s poll     also asks Android to bring its data counter up to date
#                  first: that writes the counter to disk, so it is not done
#                  every minute, only when the popout opens
#
# Almost all of it needs root (`su`, from Magisk or the ROM): what an app
# cannot read about the system. Without it only the battery (from /sys) is
# there, and the newest photos if Termux has storage permission.

echo "ps:begin 1"
echo "ps:now $(date +%s)"
echo "ps:prop model $(getprop ro.product.model 2>/dev/null)"
echo "ps:prop manufacturer $(getprop ro.product.manufacturer 2>/dev/null)"
echo "ps:prop android $(getprop ro.build.version.release 2>/dev/null)"
echo "ps:prop rom $(getprop ro.lineage.version 2>/dev/null)"
echo "ps:uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
command -v mpv >/dev/null 2>&1 && echo "ps:has mpv"

if ! su -c true >/dev/null 2>&1; then
    echo "ps:root 0"
    for f in /sys/class/power_supply/battery/capacity /sys/class/power_supply/battery/status; do
        [ -r "$f" ] && echo "ps:sys ${f##*/} $(cat "$f")"
    done
    ls -t /sdcard/DCIM/Camera/* /sdcard/Pictures/Screenshots/* /sdcard/DCIM/Screenshots/* 2>/dev/null | head -4 | sed 's/^/ps:photo /'
    echo "ps:end"
    exit 0
fi
echo "ps:root 1"

# The rest as root, in one su: each su costs a round trip to the su daemon.
su -c "sh -s ${1:-}" <<'ROOT'
[ "$1" = poll ] && dumpsys netstats --poll >/dev/null 2>&1

dumpsys battery 2>/dev/null | sed 's/^ */ps:battery /'

for p in gsm.operator.alpha gsm.network.type gsm.sim.state gsm.operator.isroaming; do
    echo "ps:prop $p $(getprop $p)"
done
echo "ps:setting airplane $(settings get global airplane_mode_on)"
echo "ps:setting zen $(settings get global zen_mode)"
echo "ps:setting ringer $(settings get global mode_ringer)"

# One block per SIM slot: whether it is registered, on what, how strong.
dumpsys telephony.registry 2>/dev/null |
    grep -E 'Phone Id=|^ *mServiceState=|^ *mSignalStrength=|^ *mDataConnectionState=|mActiveDataSubId=' |
    sed 's/^ */ps:tel /'

cmd wifi status 2>/dev/null | grep -E '^Wifi is|^WifiInfo:' | head -4 | sed 's/^/ps:wifi /'

# The hotspot: which interfaces share the connection, and how many devices
# are on them right now.
for i in $(dumpsys tethering 2>/dev/null | sed -n 's/^ *\([^ ]*\) - TetheredState.*/\1/p'); do
    n=$(ip neigh show dev "$i" 2>/dev/null | grep -c -E 'lladdr .*(REACHABLE|STALE|DELAY|PROBE)')
    echo "ps:tether $i $n"
done

df -k /data 2>/dev/null | tail -1 | sed 's/^/ps:df /'

# Android's own mobile data counter -- what Settings > Network > Data usage
# shows: its cycle and warning from the data policy, and the counter itself,
# summed here into one line per hour for the last 40 days. "Xt" is the
# per-interface record Settings reads; a mobile network is type=0, and the
# policy counts metered ones. Both sets are counted: set=ALL is what the
# kernel saw, set=DEFAULT what hardware tethering offload carried past it.
dumpsys netpolicy 2>/dev/null | grep 'NetworkPolicy{' | sed 's/^ */ps:policy /'
dumpsys netstats --full 2>/dev/null | awk -v since="$(( $(date +%s) - 40 * 86400 ))" '
    /^Xt stats:/ { xt = 1; next }
    xt && /^[^ ]/ { xt = 0 }
    xt && /ident=/ { mobile = ($0 ~ /type=0,/ && $0 ~ /metered=true/ && $0 ~ /tag=0x0/); next }
    xt && mobile && /^ *st=/ {
        st = $1; sub(/st=/, "", st)
        if (st + 0 < since) next
        rb = $2; sub(/rb=/, "", rb); tb = $4; sub(/tb=/, "", tb)
        rx[st] += rb; tx[st] += tb
    }
    END { for (s in rx) printf "ps:data %s %.0f %.0f\n", s, rx[s], tx[s] }'

# The notifications on the phone, one line each, tab separated:
#   pkg  when  flags  category  title  text  subText  bigText
dumpsys notification --noredact 2>/dev/null | awk '
    function val(s,   i) {
        i = index(s, "(")
        if (i == 0) return ""
        s = substr(s, i + 1); sub(/\)[ \t\r]*$/, "", s); gsub(/\t/, " ", s)
        return s
    }
    function field(s, name,   r) {
        if (!match(s, name "=[^ )]+")) return ""
        r = substr(s, RSTART + length(name) + 1, RLENGTH - length(name) - 1)
        return r
    }
    function flush() {
        if (pkg != "") printf "ps:notif\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pkg, when, flags, cat, title, text, subt, big
        pkg = ""; when = ""; flags = ""; cat = ""; title = ""; text = ""; subt = ""; big = ""
    }
    /^  Notification List:/ { on = 1; next }
    on && /^  [^ ]/ { flush(); on = 0 }
    !on { next }
    /^    NotificationRecord\(/ {
        flush()
        pkg = field($0, "pkg"); flags = field($0, "flags"); cat = field($0, "category")
        next
    }
    /^ +when=/ && when == "" { when = field($0, "when"); sub(/\/.*/, "", when); next }
    /^ +android\.title=/ { title = val($0); next }
    /^ +android\.text=/ { text = val($0); next }
    /^ +android\.subText=/ { subt = val($0); next }
    /^ +android\.bigText=/ { big = val($0); next }
    END { flush() }'

# Media sessions: which app, whether it is playing, and what.
dumpsys media_session 2>/dev/null | awk '
    function flush() {
        if (pkg != "") printf "ps:media\t%s\t%s\t%s\t%s\n", pkg, active, state, desc
        pkg = ""; active = ""; state = ""; desc = ""
    }
    /^User Records:/ { flush(); done = 1 }
    done { next }
    /^    package=/ { flush(); pkg = substr($0, index($0, "=") + 1); next }
    /^    active=/ { active = substr($0, index($0, "=") + 1); next }
    /^    state=/ { state = substr($0, index($0, "=") + 1); sub(/, .*/, "", state); next }
    /^    metadata:/ { i = index($0, "description="); desc = i ? substr($0, i + 12) : ""; next }
    END { flush() }'

# The newest photos and screenshots. Root's own view of shared storage: the
# /sdcard an app sees is not mounted for it.
ls -t /data/media/0/DCIM/Camera/* /data/media/0/Pictures/Screenshots/* /data/media/0/DCIM/Screenshots/* 2>/dev/null |
    head -4 | sed 's/^/ps:photo /'
ROOT

echo "ps:end"
