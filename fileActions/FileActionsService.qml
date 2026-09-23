pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "actions.js" as Actions

// One poller for the whole shell. The bar widget exists once per monitor and
// the popout comes and goes, so both sources are read here, in a singleton,
// and every surface reads the same two lists off it.
//
// Two sources, because the tool that writes these has two outputs:
//
//   live      one JSON file per running action under $XDG_RUNTIME_DIR/matrix/fct,
//             rewritten about four times a second and DELETED when the action
//             ends — so it can only ever answer "what is running now"
//   finished  one structured journal record per action, written on every exit
//             path including a kill, under the tags matrix-fct / matrix-dejavu
//
// A finished action therefore never appears in the directory at all; asking the
// journal is the only way to know how anything went.
Singleton {
    id: root

    readonly property string pluginId: "fileActions"

    // ------------------------------------------------------------ settings
    property string watchDirSetting: ""
    property int activeIntervalMs: 800
    property int idleIntervalMs: 3000
    property int journalIntervalMs: 30000
    property int historyLimit: 20
    property int staleSeconds: 45
    property bool hideWhenIdle: false

    // Both readers resolve their own paths — see scripts/live.sh. The shell that
    // runs the bar does not necessarily carry XDG_RUNTIME_DIR or even HOME
    // (a compositor started from a display manager may pass neither), and a
    // path guessed wrong in QML would look exactly like "nothing is running".
    readonly property string liveScript: Paths.strip(Qt.resolvedUrl("./scripts/live.sh"))
    readonly property string historyScript: Paths.strip(Qt.resolvedUrl("./scripts/history.sh"))

    // What the scripts reported back about that resolution, for the popout to
    // show and for `dms ipc call fileActions status` to print.
    property string runtimeBase: ""
    property var watchDirs: []
    property var presentDirs: []
    property string historySource: ""

    // --------------------------------------------------------------- state
    // Newest start first, so `current` is the action that most recently began.
    property var active: []
    property var history: []
    property bool dirPresent: true
    property bool everPolled: false
    property bool journalAvailable: true

    readonly property var current: active.length > 0 ? active[0] : null
    readonly property int activeCount: active.length

    // path -> { raw, lastChangeMs, phase, endedMs, action }
    property var _seen: ({})
    // Rows for actions whose file vanished before the journal caught up, and
    // the only history there is if the journal cannot be read at all.
    property var _fallbackHistory: []
    property var _journalHistory: []
    property real _cutoffMs: 0

    function clearHistory() {
        // The journal is not ours to delete, so "clear" means "everything
        // older than now is no longer interesting".
        root._cutoffMs = Date.now();
        root._recombine();
    }

    function refresh() {
        if (!liveProc.running)
            liveProc.running = true;
    }

    function refreshHistory() {
        if (!journalProc.running)
            journalProc.running = true;
    }

    function _recombine() {
        root.history = Actions.combineHistory(root._journalHistory, root._fallbackHistory, {
            cutoffMs: root._cutoffMs,
            historyLimit: root.historyLimit
        });
    }

    // ---------------------------------------------------------- live state
    Process {
        id: liveProc

        command: ["sh", root.liveScript, root.watchDirSetting]
        running: false

        // onStreamFinished, not onExited: `exited` fires when the process is
        // gone, which can be before the collector has drained its pipe, and a
        // short-lived script is exactly the case where it usually is. Reading
        // `text` there yields an empty string, no error and two empty lists.
        stdout: StdioCollector {
            onStreamFinished: root._ingestLive(text || "")
        }
    }

    Timer {
        interval: root.activeCount > 0 ? root.activeIntervalMs : root.idleIntervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function _ingestLive(raw) {
        const before = root.activeCount;
        const next = Actions.ingest(root._seen, root._fallbackHistory, raw, {
            nowMs: Date.now(),
            staleMs: root.staleSeconds * 1000,
            historyLimit: root.historyLimit
        });

        root.dirPresent = next.dirPresent;
        root.runtimeBase = next.header.base;
        root.watchDirs = next.header.watched;
        root.presentDirs = next.header.present;
        if (!root.everPolled)
            console.info("fileActions: watching", next.header.watched.join(" "), "(runtime base " + next.header.base + "),", next.header.present.length, "of them present");
        root.everPolled = true;
        root.active = next.active;
        root._seen = next.seen;

        if (next.historyChanged) {
            root._fallbackHistory = next.history;
            root._recombine();
        }
        // An action just ended. The wrapper logs its record before it deletes
        // its status file, so the outcome is already there — ask for it now
        // instead of waiting out the slow timer.
        if (root.activeCount < before)
            Qt.callLater(root.refreshHistory);
    }

    // ----------------------------------------------------------- event log
    Process {
        id: journalProc

        command: ["sh", root.historyScript, "600"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                const raw = text || "";
                root.historySource = Actions.parseHeader(raw).source;
                // Nothing at all means neither the state file nor the journal
                // could be read; no rows from real output just means nothing
                // has finished lately.
                root.journalAvailable = raw.length > 0;
                root._journalHistory = Actions.parseHistory(raw);
                root._recombine();
            }
        }
    }

    Timer {
        interval: root.journalIntervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refreshHistory()
    }

    // ------------------------------------------------------- plugin settings
    function _loadSettings() {
        watchDirSetting = PluginService.loadPluginData(pluginId, "watchDir", "");
        activeIntervalMs = PluginService.loadPluginData(pluginId, "activeIntervalMs", 800);
        idleIntervalMs = PluginService.loadPluginData(pluginId, "idleIntervalMs", 3000);
        journalIntervalMs = PluginService.loadPluginData(pluginId, "journalIntervalMs", 30000);
        historyLimit = PluginService.loadPluginData(pluginId, "historyLimit", 20);
        staleSeconds = PluginService.loadPluginData(pluginId, "staleSeconds", 45);
        hideWhenIdle = PluginService.loadPluginData(pluginId, "hideWhenIdle", false);
    }

    Component.onCompleted: _loadSettings()

    Connections {
        target: PluginService

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
        }
    }

    onWatchDirSettingChanged: {
        root._seen = {};
        root.active = [];
        Qt.callLater(root.refresh);
    }

    onHistoryLimitChanged: root._recombine()

    // `dms ipc call fileActions status` answers the only question worth asking
    // when the pill looks idle and should not be: which paths did it resolve,
    // and what did it find there.
    IpcHandler {
        target: "fileActions"

        function status(): string {
            return ["runtime base: " + (root.runtimeBase || "(not resolved yet)"), "watching:     " + (root.watchDirs.length ? root.watchDirs.join("  ") : "(not resolved yet)"), "present:      " + (root.presentDirs.length ? root.presentDirs.join("  ") : "none"), "history from: " + (root.historySource || "(nothing readable)"), "running:      " + root.activeCount, "finished:     " + root.history.length + " rows"].join("\n");
        }

        function refresh(): string {
            root.refresh();
            root.refreshHistory();
            return "refreshing";
        }
    }
}
