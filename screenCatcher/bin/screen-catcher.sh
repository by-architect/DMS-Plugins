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
#   - stdout line "STOPPED"         -> wf-recorder is done; GIF conversion / clipboard copy
#                                      may still be running, and further stop signals are ignored
#   - stdout line "SAVED <path>"    -> action finished, file kept at <path>
#   - stdout line "COPIED <name>"   -> action finished, clipboard only (nothing kept on disk)
#   - stdout line "TEXT <text>"     -> OCR result (shot-ocr only)
#   - stdout line "EMPTY"           -> OCR found no text (shot-ocr only)
#   - stdout line "CANCELLED"       -> user backed out of slurp (exit code 2)
#   - exit code 0   success
#   - exit code 2   cancelled (slurp aborted) — not an error
#   - anything else -> error, message is on stderr / last stdout line
#
# rec-start stops on SIGINT/SIGTERM (until STOPPED). There is no pause/resume: it was removed
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
MIX_DEV=""

setup_mix_audio() {
    # setup_mix_audio [mic-source] [system-audio-monitor]
    #
    # Combines mic input + system audio monitor into one virtual source,
    # since wf-recorder only accepts a single -a device. Three pw-loopback
    # taps: a bare mixing sink, plus one feed from the mic and one tapping the
    # default sink's monitor (stream.capture.sink=true is what makes
    # pw-loopback link to a sink's monitor ports instead of expecting a
    # source). Sets $MIX_DEV to the device name to capture, or leaves it
    # empty on failure.
    #
    # Assigns instead of printing, for the same reason set_target() does: it
    # used to be called through $(...), so it ran in a subshell and the pids
    # it collected in $mix_pids were thrown away with it. teardown_mix_audio
    # then had nothing to kill, and all three pw-loopback processes outlived
    # every recording made with both mic and system audio on — the mic stayed
    # open, the screen_catcher_mix sink stayed in the device list, and each
    # later recording stacked another trio on top (reproduced with stub
    # binaries: all three still running after the script had exited).
    #
    # The two device settings apply here too. This path only ever looked up
    # the defaults, so with both toggles on, a configured microphone or
    # system-audio device was silently ignored. The system-audio setting
    # names a monitor *source* ("<sink>.monitor", the way wf-recorder takes
    # it), while the tap below wants the sink itself.
    MIX_DEV=""
    require pw-loopback || return 1
    local src sink
    src="${1:-}"
    [ -n "$src" ] || src=$(default_source)
    sink="${2:-}"
    sink="${sink%.monitor}"
    [ -n "$sink" ] || sink=$(default_sink)
    [ -n "$src" ] && [ -n "$sink" ] || return 1

    pw-loopback -n screen_catcher_mix >/dev/null 2>&1 &
    mix_pids="$!"
    sleep 0.3

    pw-loopback -n screen_catcher_mix_mic -C "$src" -P screen_catcher_mix >/dev/null 2>&1 &
    mix_pids="$mix_pids $!"

    pw-loopback -n screen_catcher_mix_sys -C "$sink" -i '{ stream.capture.sink=true }' -P screen_catcher_mix >/dev/null 2>&1 &
    mix_pids="$mix_pids $!"

    sleep 0.3
    MIX_DEV="screen_catcher_mix.monitor"
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
        # Names only go down to the second, so a second capture inside the
        # same second (a screenshot shortcut pressed twice) got the same name
        # and grim silently overwrote the first one. Number the newcomer
        # instead.
        local base="${name%.*}" ext="${name##*.}" n=2
        while [ -e "$TARGET" ]; do
            TARGET="$outdir/${base}_$n.$ext"
            n=$((n + 1))
        done
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

# rec-start's EXIT trap: every way out of a recording goes through here,
# including a stop that lands between two steps of the setup, so the mix's
# pw-loopback processes and a clipboard-only scratch directory never outlive
# the script. Safe to run twice — teardown_mix_audio forgets the pids it has
# killed, and on the normal path finish_file has already removed the scratch
# directory.
cleanup_rec() {
    teardown_mix_audio
    if [ "$KEEPING" = "0" ] && [ -n "$workdir" ]; then
        rm -rf "$workdir"
    fi
}

# A recording is only ever stopped by the shell's Process, so a shell that went
# away mid-recording -- a crash, `dms restart`, a reload that took this script
# down with it -- left wf-recorder writing to the disk with nobody left to stop
# it. This runs beside the recording and stops it the way the stop button does,
# with SIGINT so the file is finalized, as soon as this script's parent is no
# longer the shell that started it, or the script is gone altogether. The
# parent is read from /proc rather than probed by pid, so a recycled pid cannot
# fool it. A script that is still alive carries on as after any other stop --
# conversion, clipboard, notification. One that is not leaves nobody to undo
# the audio mix or say where the recording went, so this does both.
watch_shell() {
    # watch_shell <shell pid> <script pid> <recorder pid> <file>
    local shell_pid="$1" script_pid="$2" rec_pid="$3" file="$4" stat alive
    # Never the script's own EXIT trap: cleanup_rec would delete a
    # clipboard-only recording out from under it.
    trap - EXIT INT TERM
    while kill -0 "$rec_pid" 2>/dev/null; do
        stat=""
        { read -r stat <"/proc/$script_pid/stat"; } 2>/dev/null
        # shellcheck disable=SC2086 # split "state ppid ..." into fields
        set -- ${stat##*) }
        # A killed script lingers as a zombie, parent unchanged, until that
        # parent collects it -- dead all the same.
        alive=0
        [ -n "$stat" ] && [ "${1:-}" != "Z" ] && alive=1
        if [ "$alive" = 1 ] && [ "${2:-}" = "$shell_pid" ]; then
            sleep 1
            continue
        fi
        kill -INT "$rec_pid" 2>/dev/null
        # Decided now, not once the recorder is done: by then a script that was
        # merely orphaned may have finished -- and said so -- already.
        [ "$alive" = 1 ] && return 0
        while kill -0 "$rec_pid" 2>/dev/null; do sleep 0.2; done
        teardown_mix_audio
        notify "Recording stopped" "The shell went away mid-recording. Saved: $file"
        return 0
    done
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
    # `mode` is select (default) or full, mirroring shot-select/shot-full:
    # reading the text off a whole screen is as reasonable a thing to want as
    # reading it off a dragged box.
    clipboard="$1"; NOTIFY="$2"; lang="${3:-eng}"; mode="${4:-select}"

    require grim || { echo "ERROR grim-not-found"; notify "Screenshot to text failed" "grim is not installed"; exit 1; }
    require tesseract || { echo "ERROR tesseract-not-found"; notify "Screenshot to text failed" "tesseract is not installed"; exit 1; }

    geo_args=()
    if [ "$mode" = "full" ]; then
        out=$(detect_output)
        [ -n "$out" ] && geo_args=(-o "$out")
    else
        require slurp || { echo "ERROR slurp-not-found"; notify "Screenshot to text failed" "slurp is not installed"; exit 1; }
        select_region || { echo "CANCELLED"; exit 2; }
        geo_args=(-g "$REGION")
    fi

    tmpfile=$(mktemp --suffix=.png)
    trap 'rm -f "$tmpfile"' EXIT

    if ! grim "${geo_args[@]}" "$tmpfile"; then
        notify "Screenshot to text failed" "grim could not capture the screen"
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

    # The text exists nowhere else, so a copy that was asked for and did not
    # happen (wl-clipboard missing, no Wayland clipboard) is a failed action,
    # not a quiet success — the same call finish_file makes for a
    # clipboard-only screenshot. Both this and the toggle-off case used to
    # notify "Text copied to clipboard" regardless, while the clipboard still
    # held whatever it had before.
    copied=0
    if [ "$clipboard" = "1" ]; then
        if require wl-copy && printf '%s' "$text" | wl-copy 2>/dev/null; then
            copied=1
        else
            notify "Screenshot to text failed" "Could not copy to the clipboard (is wl-clipboard installed?)"
            echo "ERROR clipboard-failed"
            exit 1
        fi
    fi

    preview="$text"
    [ "${#preview}" -gt 200 ] && preview="${preview:0:200}…"
    if [ "$copied" = "1" ]; then
        notify "Text copied to clipboard" "$preview"
    else
        notify "Text recognized" "$preview"
    fi
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

    trap cleanup_rec EXIT
    # With the shell gone, stdout is a pipe nobody reads, and the next echo
    # would kill this script before it saved what was recorded.
    trap '' PIPE

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

    # Until wf-recorder is running, a stop means "never mind": the panel
    # offers it as Cancel Recording for this whole stretch, and the mic +
    # system audio setup alone takes over half a second. Without a trap the
    # signal simply killed the script and the UI reported a failed recording.
    trap 'echo "CANCELLED"; exit 2' INT TERM

    audio_args=()
    if [ "$mic" = "1" ] && [ "$sysaudio" = "1" ]; then
        setup_mix_audio "$mic_device" "$sys_device"
        if [ -n "$MIX_DEV" ]; then
            audio_args=(-a"$MIX_DEV")
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

    # Away from stdout, which the shell reads until the last writer closes it.
    watch_shell "$PPID" "$$" "$child_pid" "$rawfile" </dev/null >/dev/null 2>&1 &

    echo "STARTED $finalfile"

    # A trap firing makes `wait` return early with 128+signo while the child
    # is still finalizing, so keep waiting until it is genuinely gone.
    while kill -0 "$child_pid" 2>/dev/null; do
        wait "$child_pid" 2>/dev/null
    done

    # The recording itself is over; what is left (the GIF palette passes, the
    # clipboard copy) has to run to the end. A second stop is the natural
    # reaction to a long GIF conversion, and with the trap simply removed it
    # killed this script mid-conversion: ffmpeg carried on as an orphan, the
    # intermediate mp4 was never deleted, the clipboard copy never happened,
    # and the UI reported a failed recording for a GIF still being written. A
    # no-op trap rather than an ignored signal, so ffmpeg and wl-copy start
    # with their own signal handling intact. STOPPED is what tells the UI to
    # stop the clock.
    trap ':' INT TERM
    echo "STOPPED"

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
