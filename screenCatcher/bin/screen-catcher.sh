#!/usr/bin/env bash
# screen-catcher.sh — capture / OCR / record helper for the Screen Catcher DMS plugin.
#
# Kept outside QML because the actual work (grim/slurp/wf-recorder/ffmpeg/tesseract/
# PipeWire audio orchestration) is much easier to get right and to test in bash
# than by building shell command arrays in JS. QML only ever starts this script
# and, for recordings, holds a handle to send it a stop signal.
#
# Audio device discovery/mixing uses native PipeWire tools (pw-dump, pw-loopback)
# rather than pactl, since a PipeWire-only system may not have the PulseAudio
# client installed. wf-recorder itself still talks pulse-protocol to
# pipewire-pulse for capture, so device names (including the "<sink>.monitor"
# convention) are the same regardless of which tool discovered them.
#
# Contract with the QML side:
#   - stdout line "STARTED <path>"  -> recording has actually begun, <path> is final output
#   - stdout line "SAVED <path>"    -> action finished, file kept at <path>
#   - stdout line "COPIED <name>"   -> action finished, clipboard only (nothing kept on disk)
#   - stdout line "TEXT <text>"     -> OCR result (shot-ocr only)
#   - stdout line "EMPTY"           -> OCR found no text (shot-ocr only)
#   - stdout line "CANCELLED"       -> user backed out of slurp (exit code 2)
#   - exit code 0   success
#   - exit code 2   cancelled (slurp aborted) — not an error
#   - anything else -> error, message is on stderr / last stdout line
#
# rec-start stops on SIGINT/SIGTERM. There is no pause/resume: it was removed
# on request, and with it the segment-splitting and ffmpeg concat pass that
# only ever existed to paper over wf-recorder having no pause of its own.

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
    # wl-copy reads the whole file into its own clipboard daemon, so the file
    # is free to be deleted straight afterwards (which is what the
    # clipboard-only, don't-keep-a-file path relies on).
    require wl-copy || return 1
    wl-copy --type "$1" <"$2" 2>/dev/null
}

mime_for() {
    # mime_for <extension>
    case "$1" in
    png) echo "image/png" ;;
    jpg | jpeg) echo "image/jpeg" ;;
    gif) echo "image/gif" ;;
    mp4) echo "video/mp4" ;;
    mkv) echo "video/x-matroska" ;;
    *) echo "application/octet-stream" ;;
    esac
}

# default_source/default_sink read the PipeWire session's default-node
# metadata directly (pw-dump + jq), which is the same information `pactl
# get-default-source/-sink` would report — just without needing pactl
# installed. Node names printed here are exactly what pipewire-pulse exposes
# over the pulse protocol, which is what wf-recorder's -a device expects.
#
# The `if type=="string"` dance matters: pw-dump emits this metadata value as
# an already-decoded JSON *object*, not as a JSON string, so the plain
# `fromjson` this used to do failed with "only strings can be parsed", both
# lookups came back empty, and "system audio" silently recorded video only.
# Older/other pw-dump builds do hand back a string, so both shapes are handled.
default_meta() {
    # default_meta <default.audio.sink|default.audio.source>
    require pw-dump && require jq || return 1
    pw-dump 2>/dev/null | jq -r --arg key "$1" '.[] | select(.type=="PipeWire:Interface:Metadata" and .props["metadata.name"]=="default") | .metadata[]? | select(.key==$key) | (.value | if type=="string" then fromjson else . end).name' 2>/dev/null | head -1
}

default_source() { default_meta "default.audio.source"; }
default_sink() { default_meta "default.audio.sink"; }

# Names the output the user is looking at, used both for grim's -o (fullscreen
# screenshot of *this* screen, not of all of them) and for wf-recorder's -o.
#
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

workdir=""

# Decides where a capture is written. With "keep to disk" off the file goes to
# a scratch directory that is deleted once it has been put on the clipboard,
# so the clipboard-only mode really does leave nothing behind. Turning *both*
# off would mean capturing into the void, so keeping the file wins in that
# case — silently discarding what the user just captured is never the helpful
# reading of two toggles being off.
KEEPING=1
TARGET=""

# Sets $TARGET (and $KEEPING/$workdir). Deliberately assigns instead of
# printing a path: called through $(...) it would run in a subshell and the
# $KEEPING/$workdir it sets would be thrown away with it, leaving the caller
# convinced every capture is being kept.
set_target() {
    # set_target <outdir> <keep> <clipboard> <basename>
    local outdir="$1" keep="$2" clipboard="$3" name="$4"
    if [ "$keep" != "1" ] && [ "$clipboard" != "1" ]; then
        keep=1
    fi
    if [ "$keep" = "1" ]; then
        mkdir -p "$outdir"
        KEEPING=1
        TARGET="$outdir/$name"
    else
        workdir=$(mktemp -d)
        KEEPING=0
        TARGET="$workdir/$name"
    fi
}

finish_file() {
    # finish_file <label> <file> <mime>
    local label="$1" file="$2" mime="$3"
    local copied=0
    [ "${CLIPBOARD:-0}" = "1" ] && copy_mime "$mime" "$file" && copied=1

    if [ "$KEEPING" = "1" ]; then
        notify "$label saved" "$file" "$file"
        echo "SAVED $file"
    else
        if [ "$copied" = "1" ]; then
            notify "$label copied" "Copied to the clipboard" "$file"
            echo "COPIED $(basename "$file")"
        else
            notify "$label failed" "Could not copy to the clipboard (is wl-clipboard installed?)"
            echo "ERROR clipboard-failed"
            rm -rf "$workdir"
            exit 1
        fi
        rm -rf "$workdir"
    fi
}

case "$cmd" in

shot-full | shot-select)
    outdir="$1"; CLIPBOARD="$2"; NOTIFY="$3"; keep="${4:-1}"; format="${5:-png}"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot failed" "grim is not installed"; exit 1; }

    geo_args=()
    if [ "$cmd" = "shot-select" ]; then
        require slurp || { echo "ERROR slurp-not-found"; notify "Screenshot failed" "slurp is not installed"; exit 1; }
        select_region || { echo "CANCELLED"; exit 2; }
        geo_args=(-g "$REGION")
    else
        # Without -o, grim captures the whole compositor layout — i.e. every
        # monitor stitched into one image, which is not what "fullscreen"
        # means to anyone with a second screen. Capture the focused output
        # only, falling back to grim's everything behaviour when no
        # compositor tool could name it.
        out=$(detect_output)
        [ -n "$out" ] && geo_args=(-o "$out")
    fi

    ext="$format"
    [ "$format" = "jpeg" ] && ext="jpg"
    set_target "$outdir" "$keep" "$CLIPBOARD" "Screenshot_$(timestamp).${ext}"
    file="$TARGET"

    if ! grim "${geo_args[@]}" -t "$format" "$file"; then
        notify "Screenshot failed" "grim could not capture the screen"
        echo "ERROR grim-failed"
        rm -rf "$workdir"
        exit 1
    fi

    finish_file "Screenshot" "$file" "$(mime_for "$ext")"
    ;;

shot-ocr)
    clipboard="$1"; NOTIFY="$2"; lang="${3:-eng}"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot to text failed" "grim is not installed"; exit 1; }
    require slurp || { echo "ERROR slurp-not-found"; notify "Screenshot to text failed" "slurp is not installed"; exit 1; }
    require tesseract || { echo "ERROR tesseract-not-found"; notify "Screenshot to text failed" "tesseract is not installed"; exit 1; }

    select_region || { echo "CANCELLED"; exit 2; }

    tmpfile=$(mktemp --suffix=.png)
    trap 'rm -f "$tmpfile"' EXIT

    if ! grim -g "$REGION" "$tmpfile"; then
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
    NOTIFY="${10:-1}"; CLIPBOARD="${11:-0}"; keep="${12:-1}"

    require wf-recorder || { echo "ERROR wf-recorder-not-found"; notify "Recording failed" "wf-recorder is not installed"; exit 1; }
    if [ "$format" = "gif" ] && ! require ffmpeg; then
        echo "ERROR ffmpeg-not-found"
        notify "GIF recording failed" "ffmpeg is required to convert a recording into a GIF"
        exit 1
    fi

    geo_args=()
    output_args=()
    if [ "$mode" = "select" ]; then
        require slurp || { echo "ERROR slurp-not-found"; notify "Recording failed" "slurp is not installed"; exit 1; }
        select_region || { echo "CANCELLED"; exit 2; }
        geo_args=(-g "$REGION")
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

    # GIF is captured as an ordinary mp4 first and palette-converted once the
    # recording is finalized (wf-recorder has no real-time GIF encoder worth
    # using). mp4/mkv record straight to the target container, since
    # wf-recorder picks the muxer from the file extension.
    ext="$format"
    [ "$format" = "gif" ] && ext="mp4"

    set_target "$outdir" "$keep" "$CLIPBOARD" "Recording_$(timestamp).${format}"
    finalfile="$TARGET"
    rawfile="$finalfile"
    [ "$format" = "gif" ] && rawfile="${finalfile%.gif}.${ext}"

    wf-recorder -y "${output_args[@]}" "${geo_args[@]}" "${audio_args[@]}" -f "$rawfile" &
    child_pid=$!

    # SIGTERM (not SIGINT) is what QML sends — see the note in
    # ScreenCatcherService.qml — and wf-recorder itself is stopped with INT,
    # which is what makes it flush and finalize the container instead of
    # leaving an unplayable file behind.
    trap 'kill -INT "$child_pid" 2>/dev/null' INT TERM

    echo "STARTED $finalfile"

    # A trap firing makes `wait` return early with 128+signo while the child
    # is still finalizing, so keep waiting until it is genuinely gone.
    while kill -0 "$child_pid" 2>/dev/null; do
        wait "$child_pid" 2>/dev/null
    done
    trap - INT TERM

    teardown_mix_audio

    if [ ! -s "$rawfile" ]; then
        rm -rf "$workdir"
        rm -f "$rawfile"
        notify "Recording failed" "No output was produced"
        echo "ERROR empty-output"
        exit 1
    fi

    if [ "$format" = "gif" ]; then
        # Quality-first conversion: a per-clip 256-colour palette built from
        # the frames that actually change (stats_mode=diff), scaled with
        # lanczos, and never upscaled past the source (min(iw,width)) since
        # blowing a 600px capture up to 1920 only makes a bigger, softer file.
        palette=$(mktemp --suffix=.png)
        vf="fps=${gif_fps},scale='min(iw\\,${gif_scale})':-1:flags=lanczos"
        ffmpeg -y -i "$rawfile" -vf "${vf},palettegen=max_colors=256:stats_mode=diff" "$palette" >/dev/null 2>&1
        ffmpeg -y -i "$rawfile" -i "$palette" -lavfi "${vf}[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle" "$finalfile" >/dev/null 2>&1
        rm -f "$palette"
        if [ -s "$finalfile" ]; then
            rm -f "$rawfile"
            finish_file "GIF" "$finalfile" "image/gif"
            exit 0
        fi
        finalfile="$rawfile"
        notify "GIF conversion failed" "Kept the raw recording instead"
        finish_file "Recording" "$finalfile" "$(mime_for "$ext")"
        exit 0
    fi

    finish_file "Recording" "$finalfile" "$(mime_for "$ext")"
    ;;

*)
    echo "ERROR unknown-command:$cmd" >&2
    exit 64
    ;;
esac
