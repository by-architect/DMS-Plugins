# Rings the phone, to find it: its own ringtone at full media volume for 15
# seconds, then the volume goes back to what it was. phoneStatus sends this
# as ssh's stdin, like remote.sh.
#
# Needs mpv in Termux (pkg install mpv), and root to turn the volume up --
# without root it plays at whatever the media volume is.

command -v mpv >/dev/null 2>&1 || { echo "ps:ring mpv is not installed in Termux"; exit 1; }

dir=
for d in /product/media/audio/ringtones /system/media/audio/ringtones /system_ext/media/audio/ringtones; do
    [ -d "$d" ] && { dir=$d; break; }
done

# The ringtone the phone is set to, when it is one of the built-in ones;
# else the first built-in one.
title=$(su -c 'settings get system ringtone' 2>/dev/null | sed -n 's/.*[?&]title=\([^&]*\).*/\1/p')
file=
[ -n "$dir" ] && [ -n "$title" ] && [ -f "$dir/$title.ogg" ] && file=$dir/$title.ogg
[ -z "$file" ] && [ -n "$dir" ] && file=$(ls "$dir"/* 2>/dev/null | head -1)
[ -n "$file" ] || { echo "ps:ring no ringtone found"; exit 1; }

# "volume is 3 in range [0..25]"
vol=$(su -c 'cmd media_session volume --stream 3 --get' 2>/dev/null | sed -n 's/.*volume is \([0-9]*\) in range \[[0-9]*\.\.\([0-9]*\)\].*/\1 \2/p')
old=${vol% *}
max=${vol#* }
[ -n "$vol" ] && su -c "cmd media_session volume --stream 3 --set $max" >/dev/null 2>&1

timeout 15 mpv --no-video --no-terminal --loop-file=inf "$file" >/dev/null 2>&1

[ -n "$vol" ] && su -c "cmd media_session volume --stream 3 --set $old" >/dev/null 2>&1
echo "ps:ring done"
