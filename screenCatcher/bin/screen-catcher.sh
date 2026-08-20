#!/usr/bin/env bash
# screen-catcher.sh — capture / OCR / record helper for the Screen Catcher DMS plugin.
#
# Kept outside QML because the actual work (grim/slurp/wf-recorder/ffmpeg/tesseract/
# PipeWire audio orchestration) is much easier to get right and to test in bash
# than by building shell command arrays in JS. QML only ever starts this script
# and, for recordings, holds a handle to send it signals (stop/pause/resume).
#
# Audio device discovery/mixing uses native PipeWire tools (pw-dump, pw-loopback)
# rather than pactl, since a PipeWire-only system may not have the PulseAudio
# client installed. wf-recorder itself still talks pulse-protocol to
# pipewire-pulse for capture, so device names (including the "<sink>.monitor"
# convention) are the same regardless of which tool discovered them.
#
# Contract with the QML side:
#   - stdout line "STARTED <path>"  -> recording has actually begun, <path> is final output
#   - stdout line "PAUSED"          -> recording paused (segment finalized, waiting)
#   - stdout line "RESUMED"         -> recording resumed (new segment started)
#   - stdout line "SAVED <path>"    -> action finished successfully
#   - stdout line "TEXT <text>"     -> OCR result (shot-ocr only)
#   - stdout line "EMPTY"           -> OCR found no text (shot-ocr only)
#   - stdout line "CANCELLED"       -> user backed out of slurp (exit code 2)
#   - exit code 0   success
#   - exit code 2   cancelled (slurp aborted) — not an error
#   - anything else -> error, message is on stderr / last stdout line
#
# rec-start signals: SIGINT/SIGTERM = stop, SIGUSR1 = pause, SIGUSR2 = resume.

set -uo pipefail

# slurp reads a list of predefined rectangles from *stdin* whenever stdin is
# not a TTY (see slurp(1)) and only shows its selection overlay once that read
# hits EOF. Quickshell's Process hands the script a pipe that is never closed,
# so every slurp started from the shell sat in read() forever: no overlay, no
# error, no exit — which is exactly what "screenshot selected", "screenshot to
# text" and "record selected" looked like from the outside (confirmed: those
# slurp processes were blocked in anon_pipe_read with no layer surface mapped).
# Detaching stdin here makes slurp see EOF immediately and fall through to
# normal interactive selection.
exec </dev/null

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

slurp_pid=""
REGION=""

# Interactive region selection. Sets $REGION and returns slurp's exit status
# (non-zero = the user cancelled). Deliberately not called through $(...):
# a command substitution runs in a subshell, so the trap below would live in
# that subshell where a stop signal sent to the script never reaches it, and
# bash defers signal handling until the substitution finishes anyway.
#
# The extra </dev/null on top of the global one keeps the helper correct when
# the script is run by hand from a pipeline.
#
# slurp runs in the background so a stop/cancel signal arriving while the user
# is still dragging can take the selection overlay down with it: an orphaned
# slurp keeps grabbing the pointer while being effectively invisible, which is
# a miserable state to leave behind.
select_region() {
    local tmp rc
    tmp=$(mktemp)
    slurp </dev/null >"$tmp" 2>/dev/null &
    slurp_pid=$!
    trap 'kill "$slurp_pid" 2>/dev/null' INT TERM
    wait "$slurp_pid"
    rc=$?
    trap - INT TERM
    slurp_pid=""
    REGION=$(cat "$tmp")
    rm -f "$tmp"
    [ -n "$REGION" ] || return 1
    return $rc
}

copy_mime() {
    # copy_mime <mime> <file>
    require wl-copy || return 0
    wl-copy --type "$1" <"$2" 2>/dev/null
}

# Respects a localized/custom Downloads folder via xdg-user-dir when
# available, falling back to the near-universal ~/Downloads.
downloads_dir() {
    if require xdg-user-dir; then
        local d
        d=$(xdg-user-dir DOWNLOAD 2>/dev/null)
        if [ -n "$d" ] && [ "$d" != "$HOME" ]; then
            echo "$d"
            return
        fi
    fi
    echo "$HOME/Downloads"
}

save_downloads() {
    # save_downloads <file>
    local dir
    dir=$(downloads_dir)
    mkdir -p "$dir" 2>/dev/null
    cp "$1" "$dir/" 2>/dev/null
}

# default_source/default_sink read the PipeWire session's default-node
# metadata directly (pw-dump + jq), which is the same information `pactl
# get-default-source/-sink` would report — just without needing pactl
# installed. Node names printed here are exactly what pipewire-pulse exposes
# over the pulse protocol, which is what wf-recorder's -a device expects.
default_source() {
    require pw-dump && require jq || return 1
    pw-dump 2>/dev/null | jq -r '.[] | select(.type=="PipeWire:Interface:Metadata" and .props["metadata.name"]=="default") | .metadata[]? | select(.key=="default.audio.source") | (.value | fromjson).name' 2>/dev/null | head -1
}

default_sink() {
    require pw-dump && require jq || return 1
    pw-dump 2>/dev/null | jq -r '.[] | select(.type=="PipeWire:Interface:Metadata" and .props["metadata.name"]=="default") | .metadata[]? | select(.key=="default.audio.sink") | (.value | fromjson).name' 2>/dev/null | head -1
}

# wf-recorder prompts *interactively* for which output to record ("Please
# select an output from the list...") whenever more than one output exists
# and -o is omitted — fatal for a backgrounded process with no terminal, it
# just hangs (confirmed: this was why "record fullscreen" silently did
# nothing on a multi-monitor system). -g mode doesn't need this since
# wf-recorder derives the output from the geometry itself.
detect_output() {
    local name
    if require hyprctl && require jq; then
        name=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused==true) | .name' 2>/dev/null | head -1)
        if [ -n "$name" ]; then
            echo "$name"
            return
        fi
    fi
    if require niri && require jq; then
        # Best-effort Niri support (untested here — no Niri session
        # available at development time). `niri msg --json focused-output`
        # is documented to print the focused output's info as JSON.
        name=$(niri msg --json focused-output 2>/dev/null | jq -r '.name // empty' 2>/dev/null | head -1)
        if [ -n "$name" ]; then
            echo "$name"
            return
        fi
    fi
    # Last resort: pick whatever wf-recorder itself lists first, so a
    # multi-monitor system without a known compositor tool at least records
    # something instead of hanging on the interactive prompt forever.
    if require wf-recorder; then
        name=$(wf-recorder -L 2>/dev/null | head -1 | sed -n 's/.*Name: \([^ ]*\).*/\1/p')
        if [ -n "$name" ]; then
            echo "$name"
            return
        fi
    fi
    echo ""
}

mix_pids=""

setup_mix_audio() {
    # Combines mic input + system audio monitor into one virtual source,
    # since wf-recorder only accepts a single -a device. Three pw-loopback
    # taps: a bare mixing sink, plus one feed from the mic and one tapping the
    # default sink's monitor (stream.capture.sink=true is what makes
    # pw-loopback link to a sink's monitor ports instead of expecting a
    # source). Prints the device name to capture, or nothing on failure.
    require pw-loopback || return 1
    local src sink
    src=$(default_source)
    sink=$(default_sink)
    [ -n "$src" ] && [ -n "$sink" ] || return 1

    pw-loopback -n screen_catcher_mix >/dev/null 2>&1 &
    mix_pids="$!"
    sleep 0.3

    pw-loopback -n screen_catcher_mix_mic -C "$src" -P screen_catcher_mix >/dev/null 2>&1 &
    mix_pids="$mix_pids $!"

    pw-loopback -n screen_catcher_mix_sys -C "$sink" -i '{ stream.capture.sink=true }' -P screen_catcher_mix >/dev/null 2>&1 &
    mix_pids="$mix_pids $!"

    sleep 0.3
    echo "screen_catcher_mix.monitor"
}

teardown_mix_audio() {
    [ -n "$mix_pids" ] || return 0
    local pid
    for pid in $mix_pids; do
        kill "$pid" 2>/dev/null
    done
    mix_pids=""
}

case "$cmd" in

shot-full)
    outdir="$1"; clipboard="$2"; NOTIFY="$3"; downloads="${4:-0}"; format="${5:-png}"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot failed" "grim is not installed"; exit 1; }

    mkdir -p "$outdir"
    ext="$format"
    [ "$format" = "jpeg" ] && ext="jpg"
    file="$outdir/Screenshot_$(timestamp).${ext}"

    if ! grim -t "$format" "$file"; then
        notify "Screenshot failed" "grim could not capture the screen"
        echo "ERROR grim-failed"
        exit 1
    fi

    mime="image/png"
    [ "$format" = "jpeg" ] && mime="image/jpeg"

    [ "$clipboard" = "1" ] && copy_mime "$mime" "$file"
    [ "$downloads" = "1" ] && save_downloads "$file"
    notify "Screenshot saved" "$file" "$file"
    echo "SAVED $file"
    ;;

shot-select)
    outdir="$1"; clipboard="$2"; NOTIFY="$3"; downloads="${4:-0}"; format="${5:-png}"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot failed" "grim is not installed"; exit 1; }
    require slurp || { echo "ERROR slurp-not-found"; notify "Screenshot failed" "slurp is not installed"; exit 1; }

    select_region || { echo "CANCELLED"; exit 2; }
    geometry="$REGION"

    mkdir -p "$outdir"
    ext="$format"
    [ "$format" = "jpeg" ] && ext="jpg"
    file="$outdir/Screenshot_$(timestamp).${ext}"

    if ! grim -g "$geometry" -t "$format" "$file"; then
        notify "Screenshot failed" "grim could not capture the selection"
        echo "ERROR grim-failed"
        exit 1
    fi

    mime="image/png"
    [ "$format" = "jpeg" ] && mime="image/jpeg"

    [ "$clipboard" = "1" ] && copy_mime "$mime" "$file"
    [ "$downloads" = "1" ] && save_downloads "$file"
    notify "Screenshot saved" "$file" "$file"
    echo "SAVED $file"
    ;;

shot-ocr)
    clipboard="$1"; NOTIFY="$2"; lang="${3:-eng}"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot to text failed" "grim is not installed"; exit 1; }
    require slurp || { echo "ERROR slurp-not-found"; notify "Screenshot to text failed" "slurp is not installed"; exit 1; }
    require tesseract || { echo "ERROR tesseract-not-found"; notify "Screenshot to text failed" "tesseract is not installed"; exit 1; }

    select_region || { echo "CANCELLED"; exit 2; }
    geometry="$REGION"

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
    outdir="$1"; mode="$2"; format="$3"; mic="$4"; sysaudio="$5"
    gif_fps="$6"; gif_scale="$7"; mic_device="${8:-}"; sys_device="${9:-}"
    NOTIFY="${10:-1}"; clipboard="${11:-0}"; downloads="${12:-0}"

    require wf-recorder || { echo "ERROR wf-recorder-not-found"; notify "Recording failed" "wf-recorder is not installed"; exit 1; }

    mkdir -p "$outdir"
    base="$outdir/Recording_$(timestamp)"

    geometry=""
    output_args=()
    if [ "$mode" = "select" ]; then
        require slurp || { echo "ERROR slurp-not-found"; notify "Recording failed" "slurp is not installed"; exit 1; }
        select_region || { echo "CANCELLED"; exit 2; }
        geometry="$REGION"
    else
        out=$(detect_output)
        [ -n "$out" ] && output_args=(-o "$out")
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

    geo_args=()
    [ -n "$geometry" ] && geo_args=(-g "$geometry")

    # GIF is captured as ordinary mp4 segments first and palette-converted as
    # a whole once finalized (wf-recorder has no real-time GIF encoder worth
    # using). mp4/mkv record straight to the target container, since
    # wf-recorder picks the muxer from the file extension.
    if [ "$format" = "gif" ]; then
        container="mp4"
        finalfile="${base}.gif"
    else
        container="$format"
        finalfile="${base}.${format}"
    fi

    # wf-recorder has no pause/resume of its own (confirmed: SIGUSR1 just
    # kills it like SIGINT does). Pause/resume is implemented here instead by
    # stopping/restarting wf-recorder across "segments" of the same
    # container, then joining them with ffmpeg's concat demuxer (lossless
    # stream copy, since every segment shares identical encoder settings) once
    # the recording is stopped for good.
    segments=()
    seg_index=0
    child_pid=""
    paused=0
    stopped=0

    start_segment() {
        seg_index=$((seg_index + 1))
        segfile="${base}.part${seg_index}.${container}"
        wf-recorder -y "${output_args[@]}" "${geo_args[@]}" "${audio_args[@]}" -f "$segfile" &
        child_pid=$!
        segments+=("$segfile")
    }

    stop_segment() {
        [ -n "$child_pid" ] || return
        kill -INT "$child_pid" 2>/dev/null
        while kill -0 "$child_pid" 2>/dev/null; do
            sleep 0.05
        done
        child_pid=""
    }

    on_pause() {
        [ "$paused" = "1" ] && return
        paused=1
        stop_segment
        echo "PAUSED"
    }

    on_resume() {
        [ "$paused" = "0" ] && return
        paused=0
        start_segment
        echo "RESUMED"
    }

    on_stop() {
        stopped=1
    }

    trap on_pause USR1
    trap on_resume USR2
    trap on_stop INT TERM

    start_segment
    echo "STARTED $finalfile"

    while [ "$stopped" = "0" ]; do
        sleep 0.1
    done

    [ "$paused" = "0" ] && stop_segment

    teardown_mix_audio

    valid_segments=()
    for s in "${segments[@]}"; do
        [ -s "$s" ] && valid_segments+=("$s")
    done

    if [ "${#valid_segments[@]}" -eq 0 ]; then
        rm -f "${segments[@]}" 2>/dev/null
        notify "Recording failed" "No output was produced"
        echo "ERROR empty-output"
        exit 1
    fi

    rawfile="${base}.${container}"
    if [ "${#valid_segments[@]}" -eq 1 ]; then
        mv "${valid_segments[0]}" "$rawfile"
    elif require ffmpeg; then
        listfile=$(mktemp --suffix=.txt)
        for s in "${valid_segments[@]}"; do
            printf "file '%s'\n" "$s" >>"$listfile"
        done
        ffmpeg -y -f concat -safe 0 -i "$listfile" -c copy "$rawfile" >/dev/null 2>&1
        rm -f "$listfile" "${valid_segments[@]}"
        if [ ! -s "$rawfile" ]; then
            notify "Recording failed" "Could not join paused segments"
            echo "ERROR concat-failed"
            exit 1
        fi
    else
        # No ffmpeg: can't join segments — keep the last one rather than
        # losing the recording outright.
        mv "${valid_segments[-1]}" "$rawfile"
        rm -f "${valid_segments[@]}" 2>/dev/null
        notify "Only the last segment was kept" "Install ffmpeg to join paused recordings into one file"
    fi

    if [ "$format" = "gif" ]; then
        if require ffmpeg; then
            palette=$(mktemp --suffix=.png)
            ffmpeg -y -i "$rawfile" -vf "fps=${gif_fps},scale=${gif_scale}:-1:flags=lanczos,palettegen" "$palette" >/dev/null 2>&1
            ffmpeg -y -i "$rawfile" -i "$palette" -lavfi "fps=${gif_fps},scale=${gif_scale}:-1:flags=lanczos[x];[x][1:v]paletteuse" "$finalfile" >/dev/null 2>&1
            rm -f "$palette"
            if [ -s "$finalfile" ]; then
                rm -f "$rawfile"
                [ "$clipboard" = "1" ] && copy_mime "image/gif" "$finalfile"
            else
                finalfile="$rawfile"
                notify "GIF conversion failed" "Kept the raw recording instead"
            fi
        else
            finalfile="$rawfile"
            notify "GIF conversion skipped" "ffmpeg is not installed; kept the raw recording"
        fi
    else
        finalfile="$rawfile"
    fi

    [ "$downloads" = "1" ] && save_downloads "$finalfile"
    notify "Recording saved" "$finalfile"
    echo "SAVED $finalfile"
    ;;

*)
    echo "ERROR unknown-command:$cmd" >&2
    exit 64
    ;;
esac
