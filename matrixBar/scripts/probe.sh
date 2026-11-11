# Matrix Bar's probe: everything one machine's part of the bar shows, read on
# that machine. Another machine runs it as ssh's `sh -s ...` with this file as
# its stdin, this one as `sh probe.sh ...`, so nothing has to be installed on
# the far end -- only a POSIX sh and /proc.
#
#   loop [interval=5] [slow=6] [self=0|1] [port=22]
#       a snapshot every <interval> seconds until the connection goes; the
#       slow parts (storage, Syncthing, a phone's call log and data counter)
#       only every <slow>th time
#   once [self=0|1] [port=22]
#       one snapshot with everything, then exit
#
# self is whether the connection this runs over is the probe's own (1) or
# one that is there anyway (0) -- an ssh ControlMaster that ssh-link keeps
# open, which the probe only rides. The probe's own is not counted as
# somebody's ssh connection. Left out, it is 1 under ssh. port is the one
# sshd listens on, for who is connected to it.
#
# Every line it prints starts with "mx:", so whatever a login file echoes on
# the way in is skipped by the reader, and mx:begin / mx:end frame one
# snapshot. Values go out raw -- CPU and GPU use are rates, so they take two
# readings -- and bar.js does the arithmetic, where it is tested.
#
# On a phone nearly all of it needs root, so there the whole loop runs
# inside one `su`: every su is a round trip to the su daemon.

mode=${1:-once}
[ $# -gt 0 ] && shift
interval=5
slow=6
self=""
port=""
for a in "$@"; do
    case $a in
        interval=*) interval=${a#*=} ;;
        slow=*) slow=${a#*=} ;;
        self=*) self=${a#*=} ;;
        port=*) port=${a#*=} ;;
    esac
done
if [ -z "$self" ]; then
    self=0
    [ -n "${SSH_CONNECTION:-}" ] && self=1
fi

android=0
if [ -f /system/build.prop ] || command -v getprop >/dev/null 2>&1; then
    android=1
fi

body() {
    cat <<'BODY'
export LC_ALL=C
# fct's logging wrappers stand in front of curl and wget on these machines;
# a status check is not a download anybody wants in that log.
export FCT_DISABLE=1
mode=$1 interval=$2 slow=$3 self=$4 android=$5 root=$6 uhome=$7 port=$8 sshconn=$9
[ -n "$uhome" ] || uhome=$HOME
[ "$slow" -ge 1 ] 2>/dev/null || slow=1
[ "$interval" -ge 1 ] 2>/dev/null || interval=5
# systemctl --user needs it, and a non-interactive ssh does not always set it.
[ -n "${XDG_RUNTIME_DIR:-}" ] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"
rundir=$XDG_RUNTIME_DIR

# df is told to leave network mounts alone (-l): a dead sshfs makes it hang.
# It also gets five seconds, when there is a timeout(1) that takes this
# syntax (old busybox does not).
t5=""
timeout 1 true >/dev/null 2>&1 && t5="timeout 5"
dfl="-l"
df -P -k -l / >/dev/null 2>&1 || dfl=""

# The real curl or wget, past any fct wrapper folder (it holds .fct-shims).
real() {
    _old=$IFS
    IFS=:
    for _d in $PATH; do
        [ -n "$_d" ] || continue
        [ -e "$_d/.fct-shims" ] && continue
        if [ -x "$_d/$1" ] && [ ! -d "$_d/$1" ]; then
            IFS=$_old
            echo "$_d/$1"
            return 0
        fi
    done
    IFS=$_old
    return 1
}

# ------------------------------------------------------------------ GPU
# Found once. Usage is what the driver says it is busy (AMD, NVIDIA, a
# phone's Adreno or Mali), or, for Intel, one minus the share of time the
# GPU spent asleep in RC6 -- a counter, so it takes two readings, like CPU.
gpu_busy=""
gpu_idle=""
for f in /sys/class/drm/card[0-9]*/device/gpu_busy_percent; do
    [ -r "$f" ] && gpu_busy="$gpu_busy $f"
done
# A phone's GPU, under the first of the names kernels give it.
for f in /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage \
         /sys/class/misc/mali0/device/utilization \
         /sys/devices/platform/*.mali/utilization \
         /sys/kernel/gpu/gpu_busy; do
    if [ -r "$f" ]; then
        gpu_busy="$gpu_busy $f"
        break
    fi
done
# One counter per card: i915's render GT (older kernels keep it under
# power/), or xe's.
for c in /sys/class/drm/card[0-9]*; do
    case ${c##*/} in *-*) continue ;; esac
    for f in "$c/gt/gt0/rc6_residency_ms" "$c/power/rc6_residency_ms" "$c/device/tile0/gt0/gtidle/idle_residency_ms"; do
        if [ -r "$f" ]; then
            gpu_idle="$gpu_idle $f"
            break
        fi
    done
done
nvsmi=""
if command -v nvidia-smi >/dev/null 2>&1; then
    nvsmi=$(command -v nvidia-smi)
fi

# A sleeping NVIDIA card in a laptop is woken up by nvidia-smi, and then
# stays awake: while the kernel has it suspended it is idle, and that is
# all there is to say.
nvidia_asleep() {
    for d in /sys/bus/pci/drivers/nvidia/0000:*; do
        [ -e "$d/power/runtime_status" ] || continue
        [ "$(cat "$d/power/runtime_status" 2>/dev/null)" = active ] && return 1
    done
    [ -d /sys/bus/pci/drivers/nvidia ]
}

sample() {
    echo "mx:cpu $(grep '^cpu ' /proc/stat 2>/dev/null)"
    up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
    for f in $gpu_idle; do
        c=${f#/sys/class/drm/}
        echo "mx:gpu idle ${c%%/*} $(cat "$f" 2>/dev/null) $up"
    done
    drm_sample "$up"
}

# Asleep in RC6 or not says little about load: a screen redrawn 120 times
# a second keeps an idle GPU half awake. What Intel's i915 does say is how
# long each program kept each engine busy, in /proc/<pid>/fdinfo -- what
# intel_gpu_top shows, without its root. Every process's files are only
# looked through on the slow snapshots (it takes a fifth of a second); the
# GPU's users found then are read every time. One line per client:
#   mx:drm <uptime> <client> <render> <copy> <video> <video-enhance> <compute>
drm_fds=""
find_drm() {
    [ -n "$gpu_idle" ] || return 0
    drm_fds=$(find /proc/[0-9]*/fd -maxdepth 1 -lname '/dev/dri/*' 2>/dev/null | sed 's|/fd/|/fdinfo/|')
}
drm_sample() {
    [ -n "$drm_fds" ] || return 0
    # The counters stay strings: as numbers, awk would print a big one as
    # 3.65586e+12.
    grep -s -H -E '^drm-(client-id|engine-[a-z-]+):' $drm_fds 2>/dev/null | awk -F: -v up="$1" '
        function z(x) { return x == "" ? "0" : x }
        { f = $1; k = $2; v = $3; gsub(/[^0-9]/, "", v) }
        k == "drm-client-id" { id[f] = v; files[f] = 1; next }
        k ~ /^drm-engine-/ { ns[f, substr(k, 12)] = v }
        END {
            for (f in files) {
                c = id[f]
                if (c in seen) continue
                seen[c] = 1
                printf "mx:drm %s %s %s %s %s %s %s\n", up, c, z(ns[f, "render"]), z(ns[f, "copy"]), z(ns[f, "video"]), z(ns[f, "video-enhance"]), z(ns[f, "compute"])
            }
        }'
}

gpu_now() {
    for f in $gpu_busy; do
        v=$(tr -dc '0-9 ' < "$f" 2>/dev/null)
        set -- $v
        case $f in
            /sys/class/drm/*) id=${f#/sys/class/drm/} id=${id%%/*} ;;
            */kgsl/*) id=adreno ;;
            *mali*) id=mali ;;
            *) id=gpu ;;
        esac
        [ -n "${1:-}" ] && echo "mx:gpu busy $id $1"
    done
    if [ -n "$nvsmi" ]; then
        if nvidia_asleep; then
            echo "mx:gpu busy nvidia 0"
        elif [ -n "$nvfile" ]; then
            for f in "$nvfile".*; do
                [ -r "$f" ] || continue
                IFS=', ' read -r i u < "$f"
                [ -n "$u" ] && echo "mx:gpu busy nvidia$i $u"
            done
        else
            "$nvsmi" --query-gpu=index,utilization.gpu --format=csv,noheader,nounits 2>/dev/null |
                while IFS=', ' read -r i u; do
                    [ -n "$u" ] && echo "mx:gpu busy nvidia$i $u"
                done
        fi
    fi
}

# Without its persistence daemon, every nvidia-smi spends a second or more
# waking the driver. A loop keeps one running instead (-l), and each
# snapshot reads the newest line it wrote per card. It stops by itself once
# this shell is gone: the next line it reads finds no parent, and
# nvidia-smi dies writing into the closed pipe.
nvfile=""
if [ -n "$nvsmi" ] && [ "$mode" = loop ] && ! nvidia_asleep; then
    nvfile=$(mktemp 2>/dev/null) || nvfile=""
fi
if [ -n "$nvfile" ]; then
    me=$$
    (
        "$nvsmi" --query-gpu=index,utilization.gpu --format=csv,noheader,nounits -l "$interval" 2>/dev/null |
            while IFS= read -r line; do
                kill -0 "$me" 2>/dev/null || break
                printf '%s\n' "$line" > "$nvfile.${line%%,*}"
            done
        rm -f "$nvfile" "$nvfile".*
    ) &
fi

# --------------------------------------------------------------- battery
# Batteries of this machine only: a mouse or headset says scope=Device.
battery() {
    for b in /sys/class/power_supply/*; do
        [ "$(cat "$b/type" 2>/dev/null)" = Battery ] || continue
        [ "$(cat "$b/scope" 2>/dev/null)" = Device ] && continue
        c=$(cat "$b/capacity" 2>/dev/null) || continue
        s=$(cat "$b/status" 2>/dev/null | tr ' ' _)
        echo "mx:bat ${b##*/} $c ${s:-Unknown}"
    done
}

# --------------------------------------------------------------- storage
# df's rows for real filesystems; the mount table's line for each of them
# (its type, and the device as the mount table names it); and for every
# device mounted from /dev, the disk it is on -- through device-mapper (LUKS,
# LVM) to what it sits on -- and whether that disk can be pulled out (the
# removable flag, or a USB or SD card bus). Only what the bar uses goes over
# the wire: a laptop on a phone's hotspot pays for every line.
storage() {
    if [ "$android" = 1 ]; then
        android_storage
        return
    fi
    rows=$($t5 df -P -k $dfl 2>/dev/null | awk 'NR > 1 && $1 !~ /^(tmpfs|devtmpfs|efivarfs|none|ramfs|overlay|shm|udev|cgroup2?|proc|sysfs|portal|gvfsd-fuse)$/')
    [ -n "$rows" ] || return 0
    printf '%s\n' "$rows" | sed 's/^/mx:df /'
    printf '%s\n' "$rows" | awk 'NR == FNR { want[$NF] = 1; next } ($2 in want) { print "mx:mnt " $1 " " $2 " " $3 }' - /proc/mounts 2>/dev/null
    printf '%s\n' "$rows" | awk 'NR == FNR { want[$NF] = 1; next } ($2 in want) && $1 ~ "^/dev/" && !seen[$1]++ { print $1 }' - /proc/mounts 2>/dev/null |
        while read -r dev; do
            n=$(readlink -f "$dev" 2>/dev/null)
            n=${n##*/}
            [ -n "$n" ] && [ -e "/sys/class/block/$n" ] || continue
            i=0
            while [ $i -lt 4 ]; do
                s=$(ls "/sys/class/block/$n/slaves" 2>/dev/null | head -n 1)
                [ -n "$s" ] || break
                n=$s
                i=$((i + 1))
            done
            p=$(readlink -f "/sys/class/block/$n")
            [ -e "/sys/class/block/$n/partition" ] && p=${p%/*}
            rm=$(cat "$p/removable" 2>/dev/null)
            case $p in
                */usb[0-9]*) bus=usb ;;
                */mmc_host/*) bus=mmc ;;
                *) bus=other ;;
            esac
            echo "mx:blk $dev ${p##*/} ${rm:-0} $bus"
        done
}

# A phone mounts shared storage per app, so no one view has all of it. What
# the user fills is /data (internal storage lives in /data/media) and each
# removable volume, which vold mounts under /mnt/media_rw in init's view --
# /proc/1/root reaches it. Each is sized with statfs and written out as a df
# row, under the /storage/<ID> name apps know it by.
android_storage() {
    m=/proc/1/mounts
    r=/proc/1/root
    [ -r "$m" ] || { m=/proc/mounts; r=""; }
    awk '$2 == "/data" || $2 ~ "^/mnt/media_rw/" { print "mx:mnt " $1 " " $2 " " $3 }' "$m" 2>/dev/null
    # awk does the sums: a phone's sh (mksh) counts in 32 bits, and a 100 GB
    # partition is past that in bytes.
    for d in /data $(awk '$2 ~ "^/mnt/media_rw/" { print $2 }' "$m" 2>/dev/null); do
        name=$d
        case $d in /mnt/media_rw/*) name=/storage/${d##*/} ;; esac
        $t5 stat -f -c '%b %f %a %S' "$r$d" 2>/dev/null |
            awk -v d="$d" -v name="$name" 'NF == 4 { k = $4 / 1024; printf "mx:df %s %.0f %.0f %.0f - %s\n", d, $1 * k, ($1 - $2) * k, $3 * k, name }'
    done
}

# ------------------------------------------------------------- the phone
# What a phone has and a computer does not: signal, Wi-Fi or mobile data,
# the call state, missed calls, and Android's own mobile data counter.
#
# The phone may be on mobile data, and so may a laptop reading it over its
# hotspot: only the fields the bar reads are sent, and the telephony and
# Wi-Fi lines only when they changed (or with the slow parts) -- bar.js keeps
# what it had.
last_phone=""
phone() {
    full=$1 data=$2
    now=$(
        for p in gsm.operator.alpha gsm.sim.state gsm.operator.isroaming ro.serialno; do
            echo "mx:prop $p $(getprop $p 2>/dev/null)"
        done
        [ "$root" = 1 ] || exit 0
        # Per SIM slot: in service or not, on what, how strong, and the call
        # state -- out of a dump many times that long.
        dumpsys telephony.registry 2>/dev/null | awk '
            function grab(s, re) {
                return match(s, re) ? substr(s, RSTART, RLENGTH) : ""
            }
            function pick(s, re,   out) {
                out = ""
                while (match(s, re)) {
                    out = out ", " substr(s, RSTART, RLENGTH)
                    s = substr(s, RSTART + RLENGTH)
                }
                return out
            }
            # Each measurement down to its strength and level, in the words
            # bar.js looks for.
            function signal(s,   out, seg) {
                out = ""
                seg = grab(s, "mLte=CellSignalStrengthLte:[^,]*")
                if (seg != "") out = out ", mLte=CellSignalStrengthLte: " grab(seg, "rsrp=-?[0-9]+") " " grab(seg, "level=[0-9]+")
                seg = grab(s, "mNr=CellSignalStrengthNr:[{][^}]*[}]")
                if (seg != "") out = out ", mNr=CellSignalStrengthNr:{ " grab(seg, "ssRsrp = -?[0-9]+") " " grab(seg, "level = [0-9]+") " }"
                seg = grab(s, "mWcdma=CellSignalStrengthWcdma:[^,]*")
                if (seg != "") out = out ", mWcdma=CellSignalStrengthWcdma: " grab(seg, "rscp=-?[0-9]+") " " grab(seg, "level=[0-9]+")
                seg = grab(s, "mGsm=CellSignalStrengthGsm:[^,]*")
                if (seg != "") out = out ", mGsm=CellSignalStrengthGsm: " grab(seg, "rssi=-?[0-9]+") " " grab(seg, "mLevel=[0-9]+")
                out = out ", " grab(s, "primary=CellSignalStrength[A-Za-z]+")
                return substr(out, 3)
            }
            /Phone Id=/ || /^ *mCallState=/ || /^ *mDataConnectionState=/ { sub(/^ */, ""); print "mx:tel " $0; next }
            /^ *mServiceState=/ {
                out = pick($0, "(mVoiceRegState|mDataRegState|getRilVoiceRadioTechnology|getRilDataRadioTechnology|roamingType)=[^ ,}]*") pick($0, "(mOperatorAlphaLong|mOperatorAlphaShort)=[^,}]*")
                print "mx:tel mServiceState={" substr(out, 3) "}"
                next
            }
            /^ *mSignalStrength=/ { print "mx:tel mSignalStrength={" signal($0) "}"; next }'
        # Whether mobile data is switched on: the setting of the SIM that
        # carries data (multi_sim_data_call names it), else the global one.
        sub=$(settings get global multi_sim_data_call 2>/dev/null)
        d=$(settings get global "mobile_data$sub" 2>/dev/null)
        case $d in 0|1) ;; *) d=$(settings get global mobile_data 2>/dev/null) ;; esac
        echo "mx:setting data $d"
        # The hotspot: the interfaces tethering shares the connection on.
        echo "mx:tether $(dumpsys tethering 2>/dev/null | sed -n 's/^ *\([^ ]*\) - TetheredState.*/\1/p' | tr '\n' ' ')"
        cmd wifi status 2>/dev/null | grep -E '^Wifi is|^WifiInfo:' | head -4 |
            sed -E 's/^(WifiInfo: SSID: "[^"]*").*(RSSI: -?[0-9]+).*/\1, \2/; s/^/mx:wifi /'
        # What carries the traffic right now: the card the default route
        # leaves by (wlan* Wi-Fi, rmnet* and friends mobile data) -- the same
        # test syncthing-guard makes before it lets Syncthing use the network.
        echo "mx:uplink $({ ip -4 route get 1.1.1.1 || ip -6 route get 2606:4700:4700::1111; } 2>/dev/null |
            sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
    )
    if [ "$full" = 1 ] || [ "$now" != "$last_phone" ]; then
        printf '%s\n' "$now"
        last_phone=$now
    fi
    [ "$root" = 1 ] || return
    if [ "$full" = 1 ]; then
        echo "mx:setting airplane $(settings get global airplane_mode_on 2>/dev/null)"
        # Missed calls not looked at yet: what the phone shows a badge for.
        n=$(content query --uri content://call_log/calls --projection _id --where "type=3 AND new=1" 2>/dev/null | grep -c '^Row:')
        echo "mx:missed $n"
    fi
    [ "$data" = 1 ] || return
    # The same counter Settings > Network > Data usage reads, with the cycle
    # and warning from the data policy. As in phoneStatus: a mobile network
    # is type=0, the policy counts metered ones, and set=ALL and set=DEFAULT
    # are both counted (hardware tethering offload carries the second past
    # the kernel). Summed into one line per day of the phone's own clock for
    # the last 40 days: a cycle starts at the beginning of a day.
    dumpsys netpolicy 2>/dev/null | grep 'NetworkPolicy{' | sed 's/^ */mx:policy /'
    off=$(date +%z 2>/dev/null | awk '{ s = substr($0, 1, 1) == "-" ? -1 : 1; print s * (substr($0, 2, 2) * 3600 + substr($0, 4, 2) * 60) }')
    dumpsys netstats --full 2>/dev/null | awk -v since="$(( $(date +%s) - 40 * 86400 ))" -v off="${off:-0}" '
        /^Xt stats:/ { xt = 1; next }
        xt && /^[^ ]/ { xt = 0 }
        xt && /ident=/ { mobile = ($0 ~ /type=0,/ && $0 ~ /metered=true/ && $0 ~ /tag=0x0/); next }
        xt && mobile && /^ *st=/ {
            st = $1; sub(/st=/, "", st)
            if (st + 0 < since) next
            day = st - (st + off) % 86400
            rb = $2; sub(/rb=/, "", rb); tb = $4; sub(/tb=/, "", tb)
            rx[day] += rb; tx[day] += tb
        }
        END { for (d in rx) printf "mx:data %.0f %.0f %.0f\n", d, rx[d], tx[d] }'
}

# ------------------------------------------------------------- processes
# One pass over /proc/*/stat: the processes worth a look, by name, each
# counted once -- a child with its parent's name (rsync's generator, a
# borg or restic worker) is part of its parent's job. comm can hold spaces
# and parentheses, so it is taken from the first "(" to the last ")". Nix
# wraps borg, which then runs as ".borg-wrapped".
#   ssh <pid>   an sshd process; its title says whose connection it is
#   rsync|borg|restic|syncthing <pid>
scan() {
    cat /proc/[0-9]*/stat 2>/dev/null | awk '
        {
            o = index($0, "(")
            c = 0
            for (i = length($0); i > o; i--) if (substr($0, i, 1) == ")") { c = i; break }
            if (!o || !c) next
            pid = substr($0, 1, o - 2)
            n = substr($0, o + 1, c - o - 1)
            sub(/^\./, "", n); sub(/-wrapped$/, "", n)
            split(substr($0, c + 2), f, " ")
            name[pid] = n; parent[pid] = f[2]
        }
        END {
            for (p in name) {
                n = name[p]
                if (n == "sshd" || n == "sshd-session") {
                    print "ssh", p
                } else if ((n == "rsync" || n == "borg" || n == "restic" || n == "syncthing") && name[parent[p]] != n) {
                    print n, p
                }
            }
        }'
}

# sshd's title for a logged-in connection is "sshd-session: user@pts/3"
# (OpenSSH 9.8 on; "sshd: user@pts/3" before), "@notty" for one without a
# terminal -- scp, rsync, a matrix fan-out, ssh-link's standing connection,
# this probe. One per connection; the root-owned "[priv]" and "[postauth]"
# halves have no "@". Then who is connected: the far end of every TCP
# connection to sshd's port, less this probe's own.
ssh_count() {
    t=0
    n=0
    for p in $(printf '%s\n' "$procs" | awk '$1 == "ssh" { print $2 }'); do
        title=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | head -n 1)
        case $title in
            sshd*@pts/*) t=$((t + 1)) ;;
            sshd*@notty*) n=$((n + 1)) ;;
        esac
    done
    echo "mx:ssh $t $n $self"
    [ -n "$port" ] && command -v ss >/dev/null 2>&1 || return 0
    own=""
    if [ "$self" = 1 ] && [ -n "$sshconn" ]; then
        set -- $sshconn
        own="${1#::ffff:}:$2"
    fi
    ss -Htn state established "( sport = :$port )" 2>/dev/null | awk -v own="$own" '
        { peer = $NF; gsub(/[][]/, "", peer); sub(/^::ffff:/, "", peer); if (peer != own) print "mx:sshpeer " peer }'
}

# ------------------------------------------------------------- jobs
last_units=""
# What is copying or backing up right now, and which of the sync and backup
# jobs failed last time:
#   mx:unit <unit> <active> <sub>     sync-backup-manager's units (systemd
#                                     --user): the sync pairs are rsync, the
#                                     backups borg
#   mx:job <kind> <percent|-> <name>  one rsync or backup running now -- a
#                                     unit's, one run by hand (fct's live
#                                     state has its progress), or the far end
#                                     of another machine's sync
jobs_now() {
    echo "mx:jobs"
    if [ "$android" = 0 ] && command -v systemctl >/dev/null 2>&1; then
        # Twenty units' lines every few seconds add up: sent when they
        # change, and with the slow parts; "mx:units same" in between.
        units=$(systemctl --user list-units 'matrix-sync-backup-manager-*' --all --no-legend --plain 2>/dev/null |
            awk '$1 ~ /^matrix-sync-backup-manager-(sync|backup)-.*\.service$/ { print "mx:unit " $1 " " $3 " " $4 }')
        if [ "$full" = 1 ] || [ "$units" != "$last_units" ]; then
            echo "mx:units"
            [ -n "$units" ] && printf '%s\n' "$units"
            last_units=$units
        else
            echo "mx:units same"
        fi
    fi
    fct=""
    [ -d "$rundir/matrix/fct" ] && fct="$rundir/matrix/fct"
    printf '%s\n' "$procs" | while read -r kind pid _; do
        case $kind in
            rsync) k=rsync ;;
            borg | restic) k=backup ;;
            *) continue ;;
        esac
        name=""
        unit=$(sed -n 's/.*\/\(matrix-sync-backup-manager-[a-z]*-[^/]*\)\.service.*/\1/p' "/proc/$pid/cgroup" 2>/dev/null | head -n 1)
        if [ -n "$unit" ]; then
            name=$unit
        elif [ "$k" = rsync ] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- ' --server'; then
            name="from another machine"
        else
            name=$kind
        fi
        pct=-
        if [ -n "$fct" ]; then
            # fct's file for an operation names its pid, or its wrapper's.
            ppid=$(awk '{ print $4 }' "/proc/$pid/stat" 2>/dev/null)
            for f in "$fct"/*.json; do
                [ -e "$f" ] || continue
                j=$(tr -d '\n' < "$f" 2>/dev/null)
                fp=$(printf '%s' "$j" | sed -n 's/.*"pid": *\([0-9]*\).*/\1/p')
                [ "$fp" = "$pid" ] || [ "$fp" = "$ppid" ] || continue
                p=$(printf '%s' "$j" | sed -n 's/.*"percent": *\([0-9.]*\).*/\1/p')
                [ -n "$p" ] && pct=$p
                t=$(printf '%s' "$j" | sed -n 's/.*"target": *"\([^"]*\)".*/\1/p')
                [ -n "$t" ] && name="to $t"
                break
            done
        fi
        echo "mx:job $k $pct $name"
    done
}

# ------------------------------------------------------------- Syncthing
# Raw answers from Syncthing's REST API; bar.js decides what they add up to.
# The API is wherever syncthing was told to listen: its --gui-address, else
# config.xml's. On a phone that is a unix socket only root can open, and
# syncthing runs in a mount namespace of its own: /proc/<pid>/root reaches
# the socket and config.xml there. `matrix sync pause` leaves a file in the
# user's home, and then the unit does not even start.
#   mx:stpause 1                 that file is there
#   mx:stoff                     no syncthing runs
#   mx:stjson <what> <json>      folders, connections, and status <folder>
syncthing_state() {
    pause="$uhome/.local/state/matrix/sync-paused"
    pid=$(printf '%s\n' "$procs" | awk '$1 == "syncthing" { print $2; exit }')
    if [ -e "$pause" ] || { [ -n "$pid" ] && [ -e "/proc/$pid/root$pause" ]; }; then
        echo "mx:stpause 1"
    fi
    if [ -z "$pid" ]; then
        echo "mx:stoff"
        return
    fi
    args=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null)
    dir=$(printf '%s\n' "$args" | sed -n 's/^--config=//p; s/^--home=//p' | head -n 1)
    gui=$(printf '%s\n' "$args" | sed -n 's/^--gui-address=//p' | head -n 1)
    if [ -z "$dir" ]; then
        for d in "$uhome/.local/state/syncthing" "$uhome/.config/syncthing"; do
            [ -e "$d/config.xml" ] && { dir=$d; break; }
        done
    fi
    xml=$dir/config.xml
    [ -r "$xml" ] || xml=/proc/$pid/root$dir/config.xml
    key=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$xml" 2>/dev/null | head -n 1)
    [ -n "$gui" ] || gui=$(sed -n '/<gui /,/<\/gui>/s:.*<address>\(.*\)</address>.*:\1:p' "$xml" 2>/dev/null | head -n 1)
    scheme=http
    sed -n '/<gui /p' "$xml" 2>/dev/null | grep -q 'tls="true"' && scheme=https
    curl=$(real curl) || { echo "mx:sterr no curl"; return; }
    [ -n "$key" ] || { echo "mx:sterr no API key in $xml"; return; }
    sock=""
    case $gui in
        unix://*) sock=${gui#unix://} ;;
        /*) sock=$gui ;;
        "") gui=127.0.0.1:8384 ;;
    esac
    if [ -n "$sock" ]; then
        [ -S "$sock" ] && [ -w "$sock" ] || sock=/proc/$pid/root$sock
        url=http://syncthing.local
    else
        host=${gui%:*}
        case $host in 0.0.0.0 | "[::]" | "") gui=127.0.0.1:${gui##*:} ;; esac
        url=$scheme://$gui
    fi
    st() {
        if [ -n "$sock" ]; then
            "$curl" -s -k -m 4 --unix-socket "$sock" -H "X-API-Key: $key" -G "$@"
        else
            "$curl" -s -k -m 4 -H "X-API-Key: $key" -G "$@"
        fi
    }
    # Only the fields bar.js reads, not Syncthing's whole answers -- these
    # were most of every snapshot.
    #   mx:stfolders, then mx:stfolder <id> <paused 0|1> <label>
    #   mx:stdevs, then mx:stdev <connected 0|1> <paused 0|1>, per device
    #   mx:ststatus <folder> <state> <files to fetch> <bytes to fetch> <failed>
    folders=$(st "$url/rest/config/folders" | tr -d '\n')
    [ -n "$folders" ] || { echo "mx:sterr its API did not answer"; return; }
    flines=$(printf '%s' "$folders" | grep -o -E '"(id|label)": *"[^"]*"|"paused": *(true|false)' | awk '
        function out() { if (id != "") printf "mx:stfolder %s %d %s\n", id, paused, label }
        { v = $0; sub(/^"[a-z]+": *"?/, "", v); sub(/"$/, "", v) }
        /^"id"/ { out(); id = v; label = ""; paused = 0; next }
        /^"label"/ { label = v; next }
        /^"paused"/ { paused = (v == "true") }
        END { out() }')
    echo "mx:stfolders"
    [ -n "$flines" ] && printf '%s\n' "$flines"
    echo "mx:stdevs"
    st "$url/rest/system/connections" | tr -d '\n' | grep -o -E '"(connected|paused)": *(true|false)' | awk '
        { k = $0; sub(/^"/, "", k); sub(/".*/, "", k); v[k] = ($0 ~ /true$/) }
        ("connected" in v) && ("paused" in v) { printf "mx:stdev %d %d\n", v["connected"], v["paused"]; delete v }'
    printf '%s\n' "$flines" | awk '$3 == 0 { print $2 }' | while read -r id; do
        [ -n "$id" ] || continue
        st --data-urlencode "folder=$id" "$url/rest/db/status" | tr -d '\n' | awk -v id="$id" '
            function val(key,   r) {
                if (!match($0, "\"" key "\": *\"?[^\",}]*")) return ""
                r = substr($0, RSTART, RLENGTH)
                sub(/^[^:]*: *"?/, "", r)
                return r
            }
            {
                state = val("state")
                if (state == "") state = "unknown"
                printf "mx:ststatus %s %s %s %s %s\n", id, state, val("needFiles") + 0, val("needBytes") + 0, val("pullErrors") + 0
            }'
    done
}

snapshot() {
    seq=$1 full=$2 data=$3
    echo "mx:begin $seq $full"
    echo "mx:t $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    [ "$full" = 1 ] && find_drm
    if [ "$seq" = 0 ]; then
        echo "mx:host $(uname -n 2>/dev/null)"
        echo "mx:android $android $root"
        echo "mx:ncpu $(grep -c '^cpu[0-9]' /proc/stat 2>/dev/null)"
        # Usage is a rate: the first snapshot takes its own two readings
        # a second apart, so the bar has numbers at once.
        sample
        sleep 1
    fi
    sample
    gpu_now
    awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } /^MemFree:/ { f = $2 }
         /^Buffers:/ { b = $2 } /^Cached:/ { c = $2 } /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
         END { if (a == "") a = f + b + c; printf "mx:mem %d %d %d %d\n", t, a, st, sf }' /proc/meminfo 2>/dev/null
    battery
    procs=$(scan)
    ssh_count
    jobs_now
    if [ "$full" = 1 ]; then
        storage
        syncthing_state
    fi
    [ "$android" = 1 ] && phone "$full" "$data"
    echo "mx:end"
}

# sh has no local variables, and the functions above use short names of
# their own (n, f, d ...): the loop's count has a name none of them takes.
tick=0
while :; do
    full=0
    data=0
    [ $((tick % slow)) -eq 0 ] && full=1
    [ $((tick % (slow * 5))) -eq 0 ] && data=1
    [ "$mode" = loop ] || { full=1; data=1; }
    snapshot "$tick" "$full" "$data"
    [ "$mode" = loop ] || break
    tick=$((tick + 1))
    sleep "$interval"
done
BODY
}

# The login user's home goes along: under su, $HOME is root's, and the file
# `matrix sync pause` leaves is in this one.
if [ "$android" = 1 ] && su -c true >/dev/null 2>&1; then
    body | su -c "sh -s $mode $interval $slow $self 1 1 '$HOME' '$port' '${SSH_CONNECTION:-}'"
else
    body | sh -s "$mode" "$interval" "$slow" "$self" "$android" 0 "$HOME" "$port" "${SSH_CONNECTION:-}"
fi
