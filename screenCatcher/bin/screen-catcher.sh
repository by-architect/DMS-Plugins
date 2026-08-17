#!/usr/bin/env bash
# screen-catcher.sh — capture / OCR / record helper for the Screen Catcher DMS plugin.
#
# Kept outside QML because the actual work (grim/slurp/wf-recorder/ffmpeg/tesseract/
# pactl orchestration) is much easier to get right and to test in bash than by
# building shell command arrays in JS. QML only ever starts this script and, for
# recordings, holds a handle to send SIGINT to it for a graceful stop.
#
# Contract with the QML side:
#   - stdout line "STARTED <path>"  -> recording has actually begun, <path> is final output
#   - stdout line "SAVED <path>"    -> action finished successfully
#   - stdout line "TEXT <text>"     -> OCR result (shot-ocr only)
#   - stdout line "EMPTY"           -> OCR found no text (shot-ocr only)
#   - stdout line "CANCELLED"       -> user backed out of slurp (exit code 2)
#   - exit code 0   success
#   - exit code 2   cancelled (slurp aborted) — not an error
#   - anything else -> error, message is on stderr / last stdout line

set -uo pipefail

cmd="${1:-}"
shift || true

NOTIFY=1

notify() {
    [ "$NOTIFY" = "1" ] || return 0
    if [ -n "${3:-}" ] && [ -f "${3:-}" ]; then
        notify-send -i "$3" "$1" "$2" 2>/dev/null
    else
        notify-send "$1" "$2" 2>/dev/null
    fi
}

require() {
    command -v "$1" >/dev/null 2>&1
}

timestamp() { date +%Y%m%d_%H%M%S; }

copy_mime() {
    # copy_mime <mime> <file>
    require wl-copy || return 0
    wl-copy --type "$1" <"$2" 2>/dev/null
}

default_source() { pactl get-default-source 2>/dev/null; }
default_sink() { pactl get-default-sink 2>/dev/null; }

mix_ids=""

setup_mix_audio() {
    # Combines mic input + system audio monitor into one virtual monitor source,
    # since wf-recorder only accepts a single -a device. Prints the device name
    # to capture, or nothing on failure.
    require pactl || return 1
    local src sink id0 id1
    src=$(default_source)
    sink=$(default_sink)
    [ -n "$src" ] && [ -n "$sink" ] || return 1
    id0=$(pactl load-module module-null-sink sink_name=screen_catcher_mix sink_properties=device.description=ScreenCatcherMix 2>/dev/null) || return 1
    id1=$(pactl load-module module-loopback source="$src" sink=screen_catcher_mix 2>/dev/null)
    id2=$(pactl load-module module-loopback source="${sink}.monitor" sink=screen_catcher_mix 2>/dev/null)
    mix_ids="$id0 ${id1:-} ${id2:-}"
    echo "screen_catcher_mix.monitor"
}

teardown_mix_audio() {
    [ -n "$mix_ids" ] || return 0
    local id
    for id in $mix_ids; do
        [ -n "$id" ] && pactl unload-module "$id" 2>/dev/null
    done
    mix_ids=""
}

case "$cmd" in

shot-full)
    outdir="$1"; clipboard="$2"; NOTIFY="$3"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot failed" "grim is not installed"; exit 1; }

    mkdir -p "$outdir"
    file="$outdir/Screenshot_$(timestamp).png"

    if ! grim "$file"; then
        notify "Screenshot failed" "grim could not capture the screen"
        echo "ERROR grim-failed"
        exit 1
    fi

    [ "$clipboard" = "1" ] && copy_mime "image/png" "$file"
    notify "Screenshot saved" "$file" "$file"
    echo "SAVED $file"
    ;;

shot-select)
    outdir="$1"; clipboard="$2"; NOTIFY="$3"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot failed" "grim is not installed"; exit 1; }
    require slurp || { echo "ERROR slurp-not-found"; notify "Screenshot failed" "slurp is not installed"; exit 1; }

    geometry=$(slurp) || { echo "CANCELLED"; exit 2; }
    [ -n "$geometry" ] || { echo "CANCELLED"; exit 2; }

    mkdir -p "$outdir"
    file="$outdir/Screenshot_$(timestamp).png"

    if ! grim -g "$geometry" "$file"; then
        notify "Screenshot failed" "grim could not capture the selection"
        echo "ERROR grim-failed"
        exit 1
    fi

    [ "$clipboard" = "1" ] && copy_mime "image/png" "$file"
    notify "Screenshot saved" "$file" "$file"
    echo "SAVED $file"
    ;;

shot-ocr)
    clipboard="$1"; NOTIFY="$2"; lang="${3:-eng}"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot to text failed" "grim is not installed"; exit 1; }
    require slurp || { echo "ERROR slurp-not-found"; notify "Screenshot to text failed" "slurp is not installed"; exit 1; }
    require tesseract || { echo "ERROR tesseract-not-found"; notify "Screenshot to text failed" "tesseract is not installed"; exit 1; }

    geometry=$(slurp) || { echo "CANCELLED"; exit 2; }
    [ -n "$geometry" ] || { echo "CANCELLED"; exit 2; }

    tmpfile=$(mktemp --suffix=.png)
    trap 'rm -f "$tmpfile"' EXIT

    if ! grim -g "$geometry" "$tmpfile"; then
        notify "Screenshot to text failed" "grim could not capture the selection"
        echo "ERROR grim-failed"
        exit 1
    fi

    text=$(tesseract "$tmpfile" - -l "$lang" 2>/dev/null)
    text="${text%$'\n'}"

    if [ -z "$text" ]; then
        notify "Screenshot to text" "No text recognized"
        echo "EMPTY"
        exit 0
    fi

    [ "$clipboard" = "1" ] && printf '%s' "$text" | wl-copy 2>/dev/null

    preview="$text"
    [ "${#preview}" -gt 200 ] && preview="${preview:0:200}…"
    notify "Text copied to clipboard" "$preview"
    printf 'TEXT %s\n' "$text"
    ;;

rec-start)
    outdir="$1"; mode="$2"; mic="$3"; sysaudio="$4"
    gif_fps="$5"; gif_scale="$6"; mic_device="${7:-}"; sys_device="${8:-}"
    NOTIFY="${9:-1}"

    require wf-recorder || { echo "ERROR wf-recorder-not-found"; notify "Recording failed" "wf-recorder is not installed"; exit 1; }
    require slurp || { echo "ERROR slurp-not-found"; notify "Recording failed" "slurp is not installed"; exit 1; }

    mkdir -p "$outdir"
    base="$outdir/Recording_$(timestamp)"

    geometry=""
    if [ "$mode" = "select" ] || [ "$mode" = "gif" ]; then
        geometry=$(slurp) || { echo "CANCELLED"; exit 2; }
        [ -n "$geometry" ] || { echo "CANCELLED"; exit 2; }
    fi

    audio_args=()
    if [ "$mic" = "1" ] && [ "$sysaudio" = "1" ]; then
        dev=$(setup_mix_audio)
        if [ -n "$dev" ]; then
            audio_args=(-a"$dev")
        else
            notify "Audio capture unavailable" "Could not combine mic and system audio; recording video only"
        fi
    elif [ "$mic" = "1" ]; then
        dev="${mic_device:-$(default_source)}"
        if [ -n "$dev" ]; then audio_args=(-a"$dev"); else audio_args=(-a); fi
    elif [ "$sysaudio" = "1" ]; then
        dev="$sys_device"
        if [ -z "$dev" ]; then
            sink=$(default_sink)
            [ -n "$sink" ] && dev="${sink}.monitor"
        fi
        if [ -n "$dev" ]; then
            audio_args=(-a"$dev")
        else
            notify "Audio capture unavailable" "Could not find the default output; recording video only"
        fi
    fi

    if [ "$mode" = "gif" ]; then
        rawfile="${base}.tmp.mp4"
        finalfile="${base}.gif"
    else
        rawfile="${base}.mp4"
        finalfile="$rawfile"
    fi

    geo_args=()
    [ -n "$geometry" ] && geo_args=(-g "$geometry")

    child_pid=""
    on_signal() {
        [ -n "$child_pid" ] && kill -INT "$child_pid" 2>/dev/null
    }

    wf-recorder -y "${geo_args[@]}" "${audio_args[@]}" -f "$rawfile" &
    child_pid=$!
    trap on_signal INT TERM

    echo "STARTED $finalfile"

    # A plain `wait` can return early (interrupted-by-trap) before the child has
    # actually exited, which would race the gif conversion / success check
    # below against wf-recorder still flushing its output. Looping on kill -0
    # guarantees we only proceed once the child is truly gone.
    while kill -0 "$child_pid" 2>/dev/null; do
        wait "$child_pid" 2>/dev/null
    done

    teardown_mix_audio

    if [ ! -s "$rawfile" ]; then
        notify "Recording failed" "No output was produced"
        echo "ERROR empty-output"
        exit 1
    fi

    if [ "$mode" = "gif" ]; then
        if require ffmpeg; then
            palette=$(mktemp --suffix=.png)
            ffmpeg -y -i "$rawfile" -vf "fps=${gif_fps},scale=${gif_scale}:-1:flags=lanczos,palettegen" "$palette" >/dev/null 2>&1
            ffmpeg -y -i "$rawfile" -i "$palette" -lavfi "fps=${gif_fps},scale=${gif_scale}:-1:flags=lanczos[x];[x][1:v]paletteuse" "$finalfile" >/dev/null 2>&1
            rm -f "$palette"
            if [ -s "$finalfile" ]; then
                rm -f "$rawfile"
                copy_mime "image/gif" "$finalfile"
            else
                # Conversion failed — keep the raw recording instead of losing it.
                finalfile="$rawfile"
                notify "GIF conversion failed" "Kept the raw recording instead"
            fi
        else
            finalfile="$rawfile"
            notify "GIF conversion skipped" "ffmpeg is not installed; kept the raw recording"
        fi
    fi

    notify "Recording saved" "$finalfile"
    echo "SAVED $finalfile"
    ;;

*)
    echo "ERROR unknown-command:$cmd" >&2
    exit 64
    ;;
esac
