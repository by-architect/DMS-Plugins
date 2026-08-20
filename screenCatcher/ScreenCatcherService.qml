pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Owns every side effect for the plugin: settings, the actual screenshot/OCR
// one-shots, and the single long-lived recording process. Being a singleton
// means every bar instance (multi-monitor) and the panel all see the exact
// same recording state and share the exact same `recProcess` — there is only
// ever one recording at a time, so that's exactly the shape we want.
Singleton {
    id: root

    readonly property string pluginId: "screenCatcher"
    readonly property string scriptPath: Paths.strip(Qt.resolvedUrl("./bin/screen-catcher.sh"))

    // ---------------------------------------------------------- settings
    // Screenshots and recordings each have their own clipboard + keep-a-file
    // pair, since wanting a screenshot on the clipboard is routine while
    // wanting a whole video on it is not (and the reverse for keeping files).
    property string screenshotDir: "~/Pictures/Screenshots"
    property string recordingDir: "~/Videos/Recordings"
    property bool copyToClipboard: true
    property bool saveToPictures: true
    property bool copyVideoToClipboard: false
    property bool saveToVideos: true
    property bool notifyOnComplete: true
    property int captureDelayMs: 900
    property string ocrLang: "eng"
    property int gifFps: 20
    property int gifScale: 1920
    property string micDevice: ""
    property string sysAudioDevice: ""
    property bool micOn: false
    property bool sysAudioOn: false
    property string imageFormat: "png"
    property string recordFormat: "mp4"

    function _loadSettings() {
        screenshotDir = PluginService.loadPluginData(pluginId, "screenshotDir", "~/Pictures/Screenshots");
        recordingDir = PluginService.loadPluginData(pluginId, "recordingDir", "~/Videos/Recordings");
        copyToClipboard = PluginService.loadPluginData(pluginId, "copyToClipboard", true);
        saveToPictures = PluginService.loadPluginData(pluginId, "saveToPictures", true);
        copyVideoToClipboard = PluginService.loadPluginData(pluginId, "copyVideoToClipboard", false);
        saveToVideos = PluginService.loadPluginData(pluginId, "saveToVideos", true);
        notifyOnComplete = PluginService.loadPluginData(pluginId, "notifyOnComplete", true);
        captureDelayMs = PluginService.loadPluginData(pluginId, "captureDelayMs", 900);
        ocrLang = PluginService.loadPluginData(pluginId, "ocrLang", "eng");
        gifFps = PluginService.loadPluginData(pluginId, "gifFps", 20);
        gifScale = PluginService.loadPluginData(pluginId, "gifScale", 1920);
        micDevice = PluginService.loadPluginData(pluginId, "micDevice", "");
        sysAudioDevice = PluginService.loadPluginData(pluginId, "sysAudioDevice", "");
        micOn = PluginService.loadPluginData(pluginId, "micOn", false);
        sysAudioOn = PluginService.loadPluginData(pluginId, "sysAudioOn", false);
        imageFormat = PluginService.loadPluginData(pluginId, "imageFormat", "png");
        recordFormat = PluginService.loadPluginData(pluginId, "recordFormat", "mp4");
    }

    Component.onCompleted: _loadSettings()

    Connections {
        target: PluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
        }
    }

    function _set(key, value) {
        root[key] = value;
        PluginService.savePluginData(pluginId, key, value);
    }

    function setMicOn(value) { _set("micOn", value); }
    function setSysAudioOn(value) { _set("sysAudioOn", value); }
    function setCopyToClipboard(value) { _set("copyToClipboard", value); }
    function setSaveToPictures(value) { _set("saveToPictures", value); }
    function setCopyVideoToClipboard(value) { _set("copyVideoToClipboard", value); }
    function setSaveToVideos(value) { _set("saveToVideos", value); }
    function setNotifyOnComplete(value) { _set("notifyOnComplete", value); }
    function setImageFormat(value) { _set("imageFormat", value); }
    function setRecordFormat(value) { _set("recordFormat", value); }

    function _dir(path) {
        return Paths.expandTilde(path);
    }

    function _bool(v) {
        return v ? "1" : "0";
    }

    // The panel closes itself immediately when an action is triggered (so it
    // doesn't end up in the screenshot/recording), which destroys its QML tree
    // right away since it's LazyLoader-backed. A Timer living inside that
    // about-to-be-destroyed window never gets the chance to fire, so the delay
    // has to live here instead, in the singleton, which outlives the panel.
    //
    // Destroying the window is not the same as it being off the screen: the
    // compositor animates the layer surface out, and grim happily captures
    // that fade. Measured on Hyprland 0.55 with its default layer animation,
    // comparing the panel's screen region against a clean reference frame:
    //
    //   50ms 20dB · 150ms 26dB · 250ms 32dB · 350ms 36dB · 450ms 48dB
    //   650ms 63dB · 800ms pixel-identical
    //
    // — i.e. the fade runs about 700ms, and the 100ms and 350ms this waited
    // before both landed mid-fade with the panel plainly visible in the shot.
    // 900ms clears it with margin (verified pixel-identical three times over).
    // The fade is the compositor's, so its length is not ours to know: the
    // delay is a setting, and adding `layerrule = noanim, dms:screen-catcher`
    // to a Hyprland config removes the animation entirely and lets it go back
    // down to ~150ms.
    property var _pendingAction: null

    function runAfterClose(action) {
        _pendingAction = action;
        closeDelay.restart();
    }

    Timer {
        id: closeDelay
        interval: root.captureDelayMs
        repeat: false
        onTriggered: {
            if (root._pendingAction)
                root._pendingAction();
            root._pendingAction = null;
        }
    }

    // ------------------------------------------------------------- toasts
    //
    // Success is reported once, when the file is actually finished — never on
    // start, and never mid-recording. The script prints "SAVED <path>" when it
    // kept a file and "COPIED <name>" when the capture only went to the
    // clipboard, which is all the UI needs to say something accurate.
    function _reportResult(label, stdout) {
        const lines = (stdout || "").trim().split("\n");
        const last = lines[lines.length - 1] || "";
        if (last.indexOf("SAVED ") === 0) {
            const path = last.substring(6);
            ToastService.showInfo(label + " saved", path.split("/").pop());
            return;
        }
        if (last.indexOf("COPIED ") === 0)
            ToastService.showInfo(label + " copied to clipboard", last.substring(7));
    }

    // -------------------------------------------------------- screenshots

    // slurp/tesseract are interactive/human-paced — the shared Proc helper's
    // default 10s timeout was firing while the user was still positioning
    // slurp, killing it and reporting a bogus error a few seconds before the
    // (still-running) slurp surface actually got composited. Both selection
    // paths disable the timeout entirely; fullscreen doesn't need slurp so it
    // keeps the default.
    function takeScreenshotFullscreen() {
        Proc.runCommand("screenCatcher.shotFull", ["bash", scriptPath, "shot-full", _dir(screenshotDir), _bool(copyToClipboard), _bool(notifyOnComplete), _bool(saveToPictures), imageFormat], (stdout, exitCode) => root._handleShotResult("Screenshot", stdout, exitCode), 0);
    }

    function takeScreenshotSelected() {
        Proc.runCommand("screenCatcher.shotSelect", ["bash", scriptPath, "shot-select", _dir(screenshotDir), _bool(copyToClipboard), _bool(notifyOnComplete), _bool(saveToPictures), imageFormat], (stdout, exitCode) => root._handleShotResult("Screenshot", stdout, exitCode), 0, Proc.noTimeout);
    }

    function screenshotToText() {
        Proc.runCommand("screenCatcher.shotOcr", ["bash", scriptPath, "shot-ocr", _bool(copyToClipboard), _bool(notifyOnComplete), ocrLang], (stdout, exitCode) => {
            if (exitCode === 2)
                return; // cancelled, stay quiet
            if (exitCode !== 0) {
                ToastService.showError("Screenshot to text failed", stdout.trim());
                return;
            }
            if (stdout.trim() === "EMPTY") {
                ToastService.showInfo("Screenshot to text", "No text recognized");
                return;
            }
            if (root.copyToClipboard)
                ToastService.showInfo("Text copied to clipboard");
        }, 0, Proc.noTimeout);
    }

    function _handleShotResult(label, stdout, exitCode) {
        if (exitCode === 2)
            return; // cancelled, stay quiet
        if (exitCode !== 0) {
            ToastService.showError(label + " failed", stdout.trim());
            return;
        }
        root._reportResult(label, stdout);
    }

    // ---------------------------------------------------------- recording

    // Derived, never assigned: a plain flag here got stuck at true whenever
    // startRecording() threw before launching anything, and because the start
    // guard refused to run while it was set, every later recording silently
    // did nothing at all. Deriving it from the process makes a stale value
    // impossible. True from launch until the script reports STARTED — i.e.
    // while slurp is up, or while audio/output setup runs.
    readonly property bool isSelecting: recProcess.running && !root.isRecording
    property bool isRecording: false
    property string recordingMode: ""
    property string recordingFormat: ""
    property string recordingOutputPath: ""
    property real recordingStartedAt: 0
    property int elapsedSeconds: 0

    readonly property var modeLabels: ({
            "full": "Full Screen",
            "select": "Selection"
        })

    readonly property string recordingLabel: (modeLabels[recordingMode] || "") + (recordingFormat ? " · " + recordingFormat.toUpperCase() : "")

    readonly property string elapsedLabel: {
        const s = Math.max(0, elapsedSeconds);
        const m = Math.floor(s / 60);
        const r = s % 60;
        return (m < 10 ? "0" : "") + m + ":" + (r < 10 ? "0" : "") + r;
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.isRecording
        onTriggered: root.elapsedSeconds = Math.floor((Date.now() - root.recordingStartedAt) / 1000)
    }

    // `format` overrides the format chips, which is how "Record Selected as
    // GIF" stays a distinct action instead of a mode you have to remember to
    // switch back off afterwards.
    function startRecording(mode, format) {
        // Guards on the process itself rather than on any state flag, so a
        // half-finished previous attempt can never wedge this permanently.
        if (root.isRecording || recProcess.running)
            return;

        const fmt = format || recordFormat;
        root.recordingMode = mode;
        root.recordingFormat = fmt;

        // No clearing of a stderr collector here: StdioCollector.text is a
        // read-only property, so assigning to it throws a TypeError that
        // aborts this function before `running = true` — which is the whole
        // reason recording used to do nothing at all, silently, while still
        // reporting OK over IPC. The collector resets itself when the next
        // process stream starts, so nothing needs clearing anyway.
        recProcess.command = ["bash", scriptPath, "rec-start", _dir(recordingDir), mode, fmt, _bool(micOn), _bool(sysAudioOn), String(gifFps), String(gifScale), micDevice, sysAudioDevice, _bool(notifyOnComplete), _bool(copyVideoToClipboard), _bool(saveToVideos)];
        recProcess.running = true;
    }

    function recordSelectedGif() {
        startRecording("select", "gif");
    }

    // Stopping targets the *wrapper script*, not wf-recorder directly — the
    // script owns the wf-recorder child and reacts by stopping and finalizing
    // it. TERM (not INT) is used deliberately: a background-started script
    // inheriting bash's "ignore SIGINT for async jobs" disposition can end up
    // completely unable to trap SIGINT for its own lifetime (confirmed by
    // testing — the same trap that worked fine for TERM never fired for INT).
    //
    // Also valid while the recording is still being set up (slurp on screen,
    // nothing recorded yet): the script kills its slurp and exits as
    // cancelled, which beats leaving an invisible selection overlay behind.
    function stopRecording() {
        if (!recProcess.running)
            return;
        recProcess.signal(15); // SIGTERM
    }

    function _resetRecordingState() {
        root.isRecording = false;
        root.recordingMode = "";
        root.recordingFormat = "";
        root.recordingOutputPath = "";
        root.recordingStartedAt = 0;
        root.elapsedSeconds = 0;
    }

    Process {
        id: recProcess

        property string finishedLabel: ""
        property string finishedOutput: ""

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                if (line.indexOf("STARTED ") === 0) {
                    root.recordingOutputPath = line.substring(8);
                    root.isRecording = true;
                    root.recordingStartedAt = Date.now();
                    root.elapsedSeconds = 0;
                } else if (line.indexOf("SAVED ") === 0 || line.indexOf("COPIED ") === 0) {
                    // Held until the process actually exits: the GIF palette
                    // pass runs after wf-recorder is done, and a toast that
                    // lands while the bar still shows a recording in progress
                    // reads as a lie.
                    recProcess.finishedLabel = root.recordingFormat === "gif" ? "GIF" : "Recording";
                    recProcess.finishedOutput = line;
                } else if (line === "CANCELLED") {
                    ToastService.showInfo("Recording cancelled");
                }
            }
        }

        stderr: StdioCollector {
            id: recStderr
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && exitCode !== 2) {
                ToastService.showError("Recording failed", recStderr.text.trim() || ("exit code " + exitCode));
            } else if (recProcess.finishedOutput) {
                root._reportResult(recProcess.finishedLabel, recProcess.finishedOutput);
            }
            recProcess.finishedLabel = "";
            recProcess.finishedOutput = "";
            root._resetRecordingState();
        }
    }
}
