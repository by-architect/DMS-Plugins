# Matrix Bar's switches: turn a phone's Wi-Fi, mobile data or hotspot on or
# off. Run on the phone as root, as `su -c 'sh -s <what> <on|off>'` with this
# file as its stdin -- over ssh, or over adb when ssh cannot reach it -- so
# nothing has to be installed there.
#
#   wifi on|off      svc wifi enable|disable
#   data on|off      svc data enable|disable: the SIM that carries data
#   hotspot on|off   Android's tethering service, the way Settings starts it
#
# Prints nothing and exits 0 when Android took it; a line saying why not
# otherwise. Whether it really switched shows in the next snapshot.

what=$1 want=$2
case $want in
    on) act=enable ;;
    off) act=disable ;;
    *) echo "on or off, not '$want'"; exit 2 ;;
esac

# `service call` answers with a hex dump of the reply parcel; the words in
# it, without UTF-16's dots between the letters.
said() {
    printf '%s\n' "$1" | sed -n "s/^[^']*'\(.*\)'.*$/\1/p" | tr -d '\n' | sed 's/\.\(.\)/\1/g; s/^\.*//; s/[. ]*$//'
}

case $what in
    wifi) svc wifi $act ;;
    data) svc data $act ;;
    hotspot)
        if [ "$want" = on ]; then
            # ITetheringConnector.startTethering (call 4) with a
            # TetheringRequestParcel: its length, then its fields in order --
            # Android 16 put a request type (2, an explicit request) in
            # front -- and those left out keep their defaults:
            #   tethering type 0 (Wi-Fi), no local or client address,
            #   exempt from the carrier's entitlement check (root may),
            #   no provisioning screen, scope 1 (shares the connection).
            # The hotspot's name and password are the ones Settings keeps.
            if [ "$(getprop ro.build.version.sdk)" -ge 36 ] 2>/dev/null; then
                head="i32 32 i32 2 i32 0"
            else
                head="i32 28 i32 0"
            fi
            out=$(service call tethering 4 i32 1 $head i32 0 i32 0 i32 1 i32 0 i32 1 s16 com.android.shell null null 2>&1)
            case $out in
                *"Parcel(NULL)"* | *"Parcel(00000000"*) ;;
                *) echo "Android refused: $(said "$out")"; exit 1 ;;
            esac
        else
            # ITetheringConnector.stopTethering (call 5), Wi-Fi. Its answer
            # goes to a listener `service call` cannot hand over, so the
            # null pointer it then trips on (exception -4, fffffffc) comes
            # after the work.
            out=$(service call tethering 5 i32 0 s16 com.android.shell null null 2>&1)
            case $out in
                *"Parcel(NULL)"* | *"Parcel(00000000"* | *"Parcel("*fffffffc*) ;;
                *) echo "Android refused: $(said "$out")"; exit 1 ;;
            esac
        fi
        ;;
    *) echo "no switch called '$what'"; exit 2 ;;
esac
