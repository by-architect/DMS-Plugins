# Call Runner's part on the phone: who can be called, and the calling. ssh
# (or adb) runs it as `sh -s <mode> [number]` with this file as its stdin,
# so nothing is installed on the phone.
#
#   contacts        every phone number in the contacts, then the newest calls
#   call <number>   rings the number from the phone, as its dialer would
#   hangup          ends the call the phone is in
#
# Every line it prints starts with "cr:", so whatever a login file echoes on
# the way in is skipped by the reader:
#   cr:serial <serial>          the phone's ro.serialno, for adb
#   cr:c <content query row>    contact_id, starred, data2 (the number's
#                               kind), data1 (the number), display_name
#   cr:r <content query row>    date, type, duration, number, name
#   cr:state <0|1|2>            the call state: idle, ringing, in a call
#   cr:ok <what>                done
#   cr:error <why>              not done
#
# The contacts and the call log are only root's to read (or an app's with the
# permission), so the whole thing runs in one `su` when there is one.

mode=${1:-contacts}
arg=${2:-}
case $arg in
    *[!0-9+*#]*) echo "cr:error not a phone number: $arg"; exit 2 ;;
esac

body() {
    cat <<'BODY'
export LC_ALL=C
mode=$1 arg=$2
PATH=$PATH:/system/bin

# `content` is a Java program, started by app_process, which needs Android's
# own environment: BOOTCLASSPATH, and ANDROID_I18N_ROOT for ICU, without
# which it prints nothing at all (and sqlite3 aborts). A Nixup or Termux sshd
# starts without it. Zygote, which starts every app, has it.
if [ -z "${ANDROID_I18N_ROOT:-}" ]; then
    for z in $(pidof zygote64 zygote 2>/dev/null); do
        [ -r "/proc/$z/environ" ] || continue
        eval "$(tr '\0' '\n' < "/proc/$z/environ" | grep -E '^(ANDROID_[A-Z0-9_]+|BOOTCLASSPATH|DEX2OATBOOTCLASSPATH|SYSTEMSERVERCLASSPATH)=' |
            sed "s/'/'\\\\''/g; s/^\([A-Z0-9_]*\)=\(.*\)$/export \1='\2'/")"
        break
    done
fi

# The busiest SIM slot's call state: 2 in a call, 1 ringing, 0 idle.
call_state() {
    dumpsys telephony.registry 2>/dev/null | sed -n 's/^ *mCallState=\([0-9]\).*/\1/p' | sort -n | tail -n 1
}

case $mode in
contacts)
    echo "cr:serial $(getprop ro.serialno 2>/dev/null)"
    # display_name last: it is the one field that may hold ", ".
    out=$(content query --uri content://com.android.contacts/data/phones --projection contact_id:starred:data2:data1:display_name 2>&1)
    rows=$(printf '%s\n' "$out" | sed -n 's/^Row: [0-9]* /cr:c /p')
    if [ -n "$rows" ]; then
        printf '%s\n' "$rows"
    elif printf '%s' "$out" | grep -q -i -E 'exception|error|denial'; then
        echo "cr:error the contacts: $(printf '%s\n' "$out" | grep -i -E 'exception|error|denial' | head -n 1)"
    fi
    # The newest calls, newest first. head ends the read early, which some
    # call log providers would not do with a LIMIT.
    content query --uri content://call_log/calls --projection date:type:duration:number:name --sort "date DESC" 2>/dev/null |
        head -n 60 | sed -n 's/^Row: [0-9]* /cr:r /p'
    echo "cr:state $(call_state)"
    echo "cr:ok contacts"
    ;;
call)
    [ -n "$arg" ] || { echo "cr:error no number"; exit 2; }
    # tel: is a URI: # would start its fragment.
    num=$(printf '%s' "$arg" | sed 's/#/%23/g')
    out=$(am start -a android.intent.action.CALL -d "tel:$num" 2>&1)
    case $out in
        *Error* | *Exception*)
            echo "cr:error $(printf '%s\n' "$out" | grep -E 'Error|Exception' | head -n 1)"
            exit 1
            ;;
    esac
    # Telecom takes a moment; a dialer that asks which SIM to use waits for
    # an answer on the phone instead.
    n=0
    s=0
    while [ $n -lt 8 ]; do
        s=$(call_state)
        [ "${s:-0}" -gt 0 ] 2>/dev/null && break
        sleep 0.5
        n=$((n + 1))
    done
    echo "cr:state ${s:-0}"
    echo "cr:ok call"
    ;;
hangup)
    s=$(call_state)
    if [ "${s:-0}" = 0 ]; then
        # ENDCALL with no call turns the screen off instead.
        echo "cr:state 0"
        echo "cr:error the phone is not in a call"
        exit 1
    fi
    input keyevent KEYCODE_ENDCALL 2>/dev/null
    sleep 1
    echo "cr:state $(call_state)"
    echo "cr:ok hangup"
    ;;
*)
    echo "cr:error unknown mode $mode"
    exit 2
    ;;
esac
BODY
}

if [ "$(id -u 2>/dev/null)" != 0 ] && su -c true >/dev/null 2>&1; then
    body | su -c "sh -s '$mode' '$arg'"
else
    body | sh -s "$mode" "$arg"
fi
