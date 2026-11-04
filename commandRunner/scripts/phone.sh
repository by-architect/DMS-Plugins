#!/usr/bin/env bash
# One thing done on an Android phone over adb, for Command Runner's phone
# commands ("run logos hotspot").
#
#   phone.sh <action>
#
#   connect      reach the phone over adb (and turn on wireless adb over USB)
#   hotspot-on   turn on the phone's hotspot and connect this computer to it
#   hotspot-off  turn the phone's hotspot off
#   mirror       show and control the phone's screen (scrcpy)
#   screenshot   take a screenshot of the phone, saved and on the clipboard
#   photo        bring over the newest photo or screenshot, on the clipboard
#   send         send the newest file in Downloads to the phone's Download
#   link         open the link on the clipboard on the phone
#   battery      battery level, charging and temperature
#   dnd          Do Not Disturb on the phone, on or off
#   lock         turn the phone's screen off
#
# From the environment (Command Runner sets them from its settings):
#   PHONE_NAME     what to call it in notifications       (default "Phone")
#   PHONE_ADDRESS  adb over the network, host:port         (empty: USB only)
#   PHONE_HOTSPOT  the hotspot's Wi-Fi name                (default: asked of
#                  the phone, else PHONE_NAME)
#
# Every outcome is a notification: Command Runner starts this detached, with
# nowhere for output to go.
#
# Needs adb; scrcpy for mirror; nmcli (NetworkManager) for hotspot-on. Turning
# the hotspot on and off needs Android 11 or newer, and reading the hotspot's
# password (only when this computer has never joined it) needs root on the
# phone.
set -uo pipefail

action=${1:-}
NAME=${PHONE_NAME:-Phone}
ADDR=${PHONE_ADDRESS:-}
SERIAL=""

notify() { # notify <title> [body] [extra dms notify flags...]
    local title=$1 body=${2:-}
    shift 2 2>/dev/null || shift $#
    if command -v dms >/dev/null 2>&1; then
        dms notify --app-name "$NAME" --app-icon phone "$@" "$title" "$body" >/dev/null 2>&1 && return
    fi
    command -v notify-send >/dev/null 2>&1 && notify-send -a "$NAME" "$title" "$body"
}

fail() {
    notify "$1" "${2:-}" --urgency critical
    exit 1
}

find_adb() {
    local c
    for c in "$(command -v adb 2>/dev/null)" "${ANDROID_HOME:-}/platform-tools/adb" \
        "${ANDROID_SDK_ROOT:-}/platform-tools/adb" "$HOME/Android/Sdk/platform-tools/adb" \
        "$HOME/Opt/Android/Sdk/platform-tools/adb"; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
ADB=$(find_adb) || fail "adb is not installed" "Install android-tools, or put the SDK's platform-tools on PATH."

adbs() { "$ADB" -s "$SERIAL" "$@"; }

# Quoted for the phone's shell, which gets adb shell's arguments as one line.
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# The one phone on a cable, if there is one.
usb_serial() {
    "$ADB" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" && $1 !~ /:[0-9]+$/ { print $1; exit }'
}

# Finds the phone: at PHONE_ADDRESS if it answers there, else on a cable.
reach() {
    if [ -n "$ADDR" ]; then
        if [ "$("$ADB" -s "$ADDR" get-state 2>/dev/null)" != device ]; then
            # An "offline" entry left from a dropped connection blocks a new one.
            "$ADB" disconnect "$ADDR" >/dev/null 2>&1
            timeout 10 "$ADB" connect "$ADDR" >/dev/null 2>&1
        fi
        if [ "$("$ADB" -s "$ADDR" get-state 2>/dev/null)" = device ]; then
            SERIAL=$ADDR
            return 0
        fi
    fi
    SERIAL=$(usb_serial)
    [ -n "$SERIAL" ] && return 0
    if [ -n "$ADDR" ]; then
        fail "$NAME is not reachable" "Nothing answers adb at $ADDR and no phone is on a cable. Plug it in, or check it is on the network with wireless debugging on."
    fi
    fail "$NAME is not connected" "No phone is on a cable, and no network address is set in Command Runner's settings."
}

sdk() { adbs shell getprop ro.build.version.sdk 2>/dev/null | tr -dc 0-9; }

# ---- the hotspot -----------------------------------------------------------
#
# Android has no shell command for the hotspot with internet sharing ("cmd wifi
# start-softap" starts one without it), so the tethering service is called the
# way the Settings toggle calls it: startTethering(TetheringRequestParcel,
# callerPkg, attributionTag, listener) -- transaction 4 of ITetheringConnector
# since Android 11. The shell user may (it holds TETHER_PRIVILEGED), as
# com.android.shell.
#
# The request is a structured parcelable: its size, then its fields in order.
# Fields past the size keep their defaults, and a reader skips what it does not
# know, so only the first few are sent. From Android 16 on they are:
#   requestType                             EXPLICIT (0)
#   tetheringType                           TETHERING_WIFI (0)
#   localIPv4Address, staticClientAddress   null
#   exemptFromEntitlementCheck              true: no carrier check
#   showProvisioningUi                      false
#   connectivityScope                       GLOBAL (1): share the internet
# Before that there was no requestType. But tethering is a module Google Play
# updates on its own, so an older Android may have either layout -- and gets
# 0 0 0 0 0 1 1, which reads right in both: the old one as wifi, null, null, no
# exemption, no UI, global; the new one as explicit, wifi, null, null, no
# exemption, UI (only shown when the carrier asks for a check), global.
# A null listener is fine: tethering checks for one before answering.
tether_on() {
    local level
    level=$(sdk)
    [ "${level:-0}" -ge 30 ] || fail "$NAME is too old for this" "Turning the hotspot on over adb needs Android 11 or newer."
    local fields
    if [ "$level" -ge 36 ]; then
        fields="i32 0 i32 0 i32 0 i32 0 i32 1 i32 0 i32 1"
    else
        fields="i32 0 i32 0 i32 0 i32 0 i32 0 i32 1 i32 1"
    fi
    # shellcheck disable=SC2086 # the fields are words on purpose
    adbs shell service call tethering 4 i32 1 i32 32 $fields s16 com.android.shell i32 -1 null >/dev/null
}

# stopTethering(type, callerPkg, attributionTag, listener) -- transaction 5.
# It answers the listener without checking for one; that throws inside the
# phone after the hotspot is off, where it is logged and nothing more.
tether_off() {
    adbs shell service call tethering 5 i32 0 s16 com.android.shell i32 -1 null >/dev/null
}

tethering_wifi() {
    adbs shell dumpsys tethering 2>/dev/null | grep -E '(wlan|softap|ap_br)[^ ]* - TetheredState' >/dev/null
}

# A value from the phone's saved hotspot settings (root only), or "".
softap_value() { # softap_value <WifiSsid|Passphrase>
    adbs shell "su -c 'cat /data/misc/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml' 2>/dev/null" 2>/dev/null |
        sed -n "s|.*name=\"$1\">\(.*\)</string>.*|\1|p" | head -1 |
        sed -E 's/^&quot;(.*)&quot;$/\1/' | # the name is saved in quotes, the password not
        sed 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'"'"'/g; s/&amp;/\&/g'
}

# The hotspot's Wi-Fi name: the setting, else the phone's own, else the
# phone's name.
hotspot_ssid() {
    if [ -n "${PHONE_HOTSPOT:-}" ]; then
        printf '%s' "$PHONE_HOTSPOT"
        return
    fi
    local ssid
    ssid=$(softap_value WifiSsid)
    printf '%s' "${ssid:-$NAME}"
}

# The NetworkManager profile that joins a Wi-Fi network, by the network's name.
nm_profile_for() {
    local want=$1 line type name
    while IFS= read -r line; do
        type=${line%%:*}
        [ "$type" = 802-11-wireless ] || continue
        name=${line#*:}
        name=${name//\\:/:}
        [ "$(nmcli -g 802-11-wireless.ssid connection show "$name" 2>/dev/null)" = "$want" ] && {
            printf '%s' "$name"
            return 0
        }
    done < <(nmcli -t -f TYPE,NAME connection show 2>/dev/null)
    return 1
}

on_wifi() {
    nmcli -t -f ACTIVE,SSID device wifi list --rescan no 2>/dev/null | grep -Fqx "yes:$1"
}

wifi_visible() { # wifi_visible <ssid> [auto|yes|no]
    nmcli -t -f SSID device wifi list --rescan "${2:-auto}" 2>/dev/null | grep -Fqx "$1"
}

join_wifi() {
    local ssid=$1 profile pass
    if profile=$(nm_profile_for "$ssid"); then
        nmcli connection up "$profile" >/dev/null 2>&1 && return 0
    fi
    # Never joined before: its password comes off the phone (root only). It is
    # on nmcli's command line for that one run; NetworkManager keeps it after.
    [ -n "$SERIAL" ] && pass=$(softap_value Passphrase)
    if [ -n "${pass:-}" ]; then
        nmcli device wifi connect "$ssid" password "$pass" >/dev/null 2>&1 && return 0
    else
        nmcli device wifi connect "$ssid" >/dev/null 2>&1 && return 0
    fi
    return 1
}

hotspot_on() {
    command -v nmcli >/dev/null 2>&1 || fail "nmcli is not installed" "Connecting to the hotspot needs NetworkManager."
    nmcli radio wifi on >/dev/null 2>&1

    local ssid=${PHONE_HOTSPOT:-$NAME}
    if on_wifi "$ssid"; then
        notify "Already on $ssid" "This computer is connected to $NAME's hotspot."
        return
    fi

    # Already on, then just join it -- and no adb needed, which matters when
    # this computer has no other network to reach the phone over.
    if ! wifi_visible "$ssid"; then
        reach
        ssid=$(hotspot_ssid)
        if ! tethering_wifi; then
            tether_on
        fi
        local _
        for _ in $(seq 1 12); do
            sleep 2
            # A scan asked for too soon after the last is refused; the list
            # is still there to read.
            nmcli device wifi rescan ssid "$ssid" >/dev/null 2>&1
            sleep 1
            wifi_visible "$ssid" no && break
        done
        wifi_visible "$ssid" no || {
            tethering_wifi && fail "Can't see $ssid" "$NAME's hotspot is on, but this computer can't find a network called \"$ssid\". Set the hotspot's Wi-Fi name in Command Runner's settings."
            fail "$NAME's hotspot did not start" "Turn it on from the phone's quick settings once, then try again."
        }
    fi

    if join_wifi "$ssid"; then
        notify "Connected to $ssid" "$NAME's hotspot is on and this computer is using it."
    else
        fail "Couldn't join $ssid" "$NAME's hotspot is on, but connecting failed. Join it once from the Wi-Fi list so its password is saved."
    fi
}

hotspot_off() {
    reach
    if ! tethering_wifi; then
        notify "$NAME's hotspot is already off"
        return
    fi
    tether_off
    sleep 2
    if tethering_wifi; then
        fail "$NAME's hotspot is still on" "Turn it off from the phone."
    fi
    notify "$NAME's hotspot is off"
}

# ---- the rest --------------------------------------------------------------

connect() {
    if [ -n "$ADDR" ] && [ "$("$ADB" -s "$ADDR" get-state 2>/dev/null)" != device ]; then
        local usb
        usb=$(usb_serial)
        # On a cable with the network address not answering: wireless adb is
        # off, as after every reboot. Turn it on, so the cable can go.
        if [ -n "$usb" ]; then
            "$ADB" -s "$usb" tcpip "${ADDR##*:}" >/dev/null 2>&1
            sleep 2
        fi
    fi
    reach
    local model
    model=$(adbs shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    notify "$NAME connected" "adb is talking to $model at $SERIAL."
}

mirror() {
    command -v scrcpy >/dev/null 2>&1 || fail "scrcpy is not installed" "Showing the phone's screen needs scrcpy."
    reach
    local args=(--serial "$SERIAL" --window-title "$NAME" --stay-awake)
    # Over the network, a smaller picture keeps it smooth.
    [[ $SERIAL == *:* ]] && args+=(--max-size 1600 --video-bit-rate 4M)
    ADB="$ADB" scrcpy "${args[@]}" >/dev/null 2>&1 &
    disown
}

pictures_dir() {
    local d
    d=$(xdg-user-dir PICTURES 2>/dev/null)
    [ -n "$d" ] && [ "$d" != "$HOME" ] || d=$HOME/Pictures
    printf '%s' "$d"
}

downloads_dir() {
    local d
    d=$(xdg-user-dir DOWNLOAD 2>/dev/null)
    [ -n "$d" ] && [ "$d" != "$HOME" ] || d=$HOME/Downloads
    printf '%s' "$d"
}

copy_image() { # copy_image <file>
    local type=image/png
    case ${1,,} in *.jpg | *.jpeg) type=image/jpeg ;; *.webp) type=image/webp ;; esac
    dms cl copy --type "$type" <"$1" >/dev/null 2>&1 || wl-copy --type "$type" <"$1" 2>/dev/null
}

screenshot() {
    reach
    local dir file
    dir=$(pictures_dir)/Screenshots
    mkdir -p "$dir"
    file="$dir/$NAME-$(date +%Y%m%d-%H%M%S).png"
    if ! adbs exec-out screencap -p >"$file" 2>/dev/null || [ ! -s "$file" ]; then
        rm -f "$file"
        fail "Couldn't take a screenshot of $NAME"
    fi
    copy_image "$file"
    notify "Screenshot of $NAME" "Copied, and saved as ${file/#$HOME/\~}" --icon "$file" --file "$file"
}

photo() {
    reach
    local remote dir local_file
    remote=$(adbs shell 'ls -t /sdcard/DCIM/Camera/* /sdcard/Pictures/Screenshots/* /sdcard/DCIM/Screenshots/* 2>/dev/null | head -1' | tr -d '\r')
    [ -n "$remote" ] || fail "No photos on $NAME" "Nothing in DCIM/Camera or Pictures/Screenshots."
    dir=$(downloads_dir)
    mkdir -p "$dir"
    local_file="$dir/$(basename "$remote")"
    adbs pull "$remote" "$local_file" >/dev/null 2>&1 || fail "Couldn't bring over $(basename "$remote")"
    copy_image "$local_file"
    notify "$(basename "$remote")" "The newest photo on $NAME — copied, and saved in ${dir/#$HOME/\~}" --icon "$local_file" --file "$local_file"
}

send() {
    local dir file
    dir=$(downloads_dir)
    # The newest finished file: not a browser's half-done download.
    file=$(find "$dir" -maxdepth 1 -type f ! -name '*.part' ! -name '*.crdownload' ! -name '*.tmp' ! -name '.*' \
        -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)
    [ -n "$file" ] || fail "Nothing to send" "${dir/#$HOME/\~} is empty."
    reach
    local name
    name=$(basename "$file")
    adbs push "$file" "/sdcard/Download/$name" >/dev/null 2>&1 || fail "Couldn't send $name"
    # So it shows up in the phone's gallery and file pickers at once.
    adbs shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
        -d "$(quote "file:///sdcard/Download/$name")" >/dev/null 2>&1
    notify "Sent $name" "It is in $NAME's Download folder."
}

link() {
    local url
    url=$(dms cl paste 2>/dev/null || wl-paste --no-newline 2>/dev/null)
    url=$(printf '%s' "$url" | head -1 | tr -d '[:space:]')
    [[ $url =~ ^(https?|mailto|tel|geo|market|intent):.+ ]] || fail "No link on the clipboard" "Copy a link first."
    reach
    adbs shell am start -a android.intent.action.VIEW -d "$(quote "$url")" >/dev/null 2>&1 || fail "$NAME couldn't open the link"
    # Wake the screen, so the page is there when the phone is picked up.
    adbs shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    notify "Opened on $NAME" "$url"
}

battery() {
    reach
    local info level status temp plugged state
    info=$(adbs shell dumpsys battery 2>/dev/null | tr -d '\r')
    level=$(awk -F': ' '/^  level:/ { print $2; exit }' <<<"$info")
    status=$(awk -F': ' '/^  status:/ { print $2; exit }' <<<"$info")
    temp=$(awk -F': ' '/^  temperature:/ { print $2; exit }' <<<"$info")
    plugged=$(grep -E '^  (AC|USB|Wireless|Dock) powered: true' <<<"$info" | sed 's/^  \([A-Za-z]*\).*/\1/' | head -1)
    case $status in
    2) state="charging${plugged:+ ($plugged)}" ;;
    5) state="full" ;;
    3 | 4) state="on battery" ;;
    *) state="" ;;
    esac
    local body="${state}"
    [ -n "$temp" ] && body="${body:+$body · }$((temp / 10)).$((temp % 10)) °C"
    notify "$NAME: ${level:-?}%" "$body"
}

dnd() {
    reach
    local mode
    mode=$(adbs shell settings get global zen_mode 2>/dev/null | tr -dc 0-9)
    if [ "${mode:-0}" = 0 ]; then
        adbs shell cmd notification set_dnd priority >/dev/null 2>&1 || fail "Couldn't change Do Not Disturb"
        notify "$NAME: Do Not Disturb on" "Only priority calls and messages get through."
    else
        adbs shell cmd notification set_dnd off >/dev/null 2>&1 || fail "Couldn't change Do Not Disturb"
        notify "$NAME: Do Not Disturb off"
    fi
}

lock() {
    reach
    adbs shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1 || fail "Couldn't lock $NAME"
    notify "$NAME locked" "" --transient
}

case $action in
connect) connect ;;
hotspot-on) hotspot_on ;;
hotspot-off) hotspot_off ;;
mirror) mirror ;;
screenshot) screenshot ;;
photo) photo ;;
send) send ;;
link) link ;;
battery) battery ;;
dnd) dnd ;;
lock) lock ;;
*)
    sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 2
    ;;
esac
