pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Owns every side effect for the plugin: settings, the actual screenshot/OCR
// one-shots, and the single long-lived recording process. Being a singleton
// means every bar instance (multi-monitor) and the popout all see the exact
// same recording state and share the exact same `recProcess` — there is only
// ever one recording at a time, so that's exactly the shape we want.
Singleton {
    id: root

    readonly property string pluginId: "screenCatcher"
    readonly property string scriptPath: Paths.strip(Qt.resolvedUrl("./bin/screen-catcher.sh"))

    // ---------------------------------------------------------- settings
    property string screenshotDir: "~/Pictures/Screenshots"
    property string recordingDir: "~/Videos/Recordings"
    property bool copyToClipboard: true
    property bool notifyOnComplete: true
    property string ocrLang: "eng"
    property int gifFps: 12
    property int gifScale: 480
    property string micDevice: ""
    property string sysAudioDevice: ""
    property bool micOn: false
    property bool sysAudioOn: false

    function _loadSettings() {
        screenshotDir = PluginService.loadPluginData(pluginId, "screenshotDir", "~/Pictures/Screenshots");
        recordingDir = PluginService.loadPluginData(pluginId, "recordingDir", "~/Videos/Recordings");
        copyToClipboard = PluginService.loadPluginData(pluginId, "copyToClipboard", true);
        notifyOnComplete = PluginService.loadPluginData(pluginId, "notifyOnComplete", true);
        ocrLang = PluginService.loadPluginData(pluginId, "ocrLang", "eng");
        gifFps = PluginService.loadPluginData(pluginId, "gifFps", 12);
        gifScale = PluginService.loadPluginData(pluginId, "gifScale", 480);
        micDevice = PluginService.loadPluginData(pluginId, "micDevice", "");
        sysAudioDevice = PluginService.loadPluginData(pluginId, "sysAudioDevice", "");
        micOn = PluginService.loadPluginData(pluginId, "micOn", false);
        sysAudioOn = PluginService.loadPluginData(pluginId, "sysAudioOn", false);
    }

    Component.onCompleted: _loadSettings()

    Connections {
        target: PluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
        }
    }

    function setMicOn(value) {
        root.micOn = value;
        PluginService.savePluginData(pluginId, "micOn", value);
    }

    function setSysAudioOn(value) {
        root.sysAudioOn = value;
        PluginService.savePluginData(pluginId, "sysAudioOn", value);
    }

    function _dir(path) {
        return Paths.expandTilde(path);
    }

    function _bool(v) {
        return v ? "1" : "0";
    }

    // -------------------------------------------------------- screenshots

    function takeScreenshotFullscreen() {
        Proc.runCommand("screenCatcher.shotFull", ["bash", scriptPath, "shot-full", _dir(screenshotDir), _bool(copyToClipboard), _bool(notifyOnComplete)], (stdout, exitCode) => root._handleShotResult("Screenshot", stdout, exitCode));
    }

    function takeScreenshotSelected() {
        Proc.runCommand("screenCatcher.shotSelect", ["bash", scriptPath, "shot-select", _dir(screenshotDir), _bool(copyToClipboard), _bool(notifyOnComplete)], (stdout, exitCode) => root._handleShotResult("Screenshot", stdout, exitCode));
    }

    function screenshotToText() {
        Proc.runCommand("screenCatcher.shotOcr", ["bash", scriptPath, "shot-ocr", _bool(copyToClipboard), _bool(notifyOnComplete), ocrLang], (stdout, exitCode) => {
            if (exitCode === 2)
                return; // cancelled, stay quiet
            if (exitCode !== 0) {
                ToastService.showError("Screenshot to text failed", stdout.trim());
                return;
            }
            if (stdout.trim() === "EMPTY")
                ToastService.showInfo("Screenshot to text", "No text recognized");
        });
    }

    function _handleShotResult(label, stdout, exitCode) {
        if (exitCode === 2)
            return; // cancelled, stay quiet
        if (exitCode !== 0)
            ToastService.showError(label + " failed", stdout.trim());
    }

    // ---------------------------------------------------------- recording

    property bool isSelecting: false
    property bool isRecording: false
    property string recordingMode: ""
    property string recordingOutputPath: ""
    property real recordingStartedAt: 0
    property int elapsedSeconds: 0

    readonly property var modeLabels: ({
            "full": "Full Screen",
            "select": "Selection",
            "gif": "Selection (GIF)"
        })

    readonly property string recordingLabel: modeLabels[recordingMode] || ""

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

    function startRecording(mode) {
        if (root.isRecording || root.isSelecting)
            return;

        root.isSelecting = mode !== "full";
        root.recordingMode = mode;

        recProcess.command = ["bash", scriptPath, "rec-start", _dir(recordingDir), mode, _bool(micOn), _bool(sysAudioOn), String(gifFps), String(gifScale), micDevice, sysAudioDevice, _bool(notifyOnComplete)];
        recStderr.text = "";
        recProcess.running = true;
    }

    function stopRecording() {
        if (!root.isRecording)
            return;
        recProcess.signal(2); // SIGINT — the script forwards this to wf-recorder and finalizes the file
    }

    function _resetRecordingState() {
        root.isSelecting = false;
        root.isRecording = false;
        root.recordingMode = "";
        root.recordingOutputPath = "";
        root.recordingStartedAt = 0;
        root.elapsedSeconds = 0;
    }

    Process {
        id: recProcess

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                if (line.indexOf("STARTED ") === 0) {
                    root.recordingOutputPath = line.substring(8);
                    root.isSelecting = false;
                    root.isRecording = true;
                    root.recordingStartedAt = Date.now();
                    root.elapsedSeconds = 0;
                } else if (line === "CANCELLED") {
                    ToastService.showInfo("Recording cancelled");
                }
            }
        }

        stderr: StdioCollector {
            id: recStderr
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && exitCode !== 2)
                ToastService.showError("Recording failed", recStderr.text.trim() || ("exit code " + exitCode));
            root._resetRecordingState();
        }
    }
}
