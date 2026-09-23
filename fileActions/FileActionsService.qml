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

    // Both names are watched: the wrapper was called dejavu before it was
    // called fct, and which one is installed depends on the generation this
    // machine booted.
    readonly property var watchDirs: {
        const custom = (watchDirSetting || "").trim();
        if (custom)
            return [custom.replace(/\/+$/, "")];
        const runtime = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp";
        return [runtime + "/matrix/fct", runtime + "/matrix/dejavu"];
    }

    // The event log, in order of preference: the wrappers append one JSON
    // record per line to a file under the user's own state directory, and the
    // same records also go to the journal. The file is cheaper to read and
    // does not depend on journal access, so it wins when it is there.
    readonly property var historyPaths: [Quickshell.env("HOME") + "/.local/state/fct.json", Quickshell.env("HOME") + "/.local/state/dejavu.json"]
    readonly property string journalCommand: "journalctl -o json --no-pager --since '-14 days' -n 600 -t matrix-fct -t matrix-dejavu 2>/dev/null"

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
    // One sh pass over every watched directory: a marker, the file's path,
    // then the file itself. Each file is parsed on its own, so a file caught
    // between the writer's tmp+rename costs its own row for one poll rather
    // than the whole list.
    function _liveScript() {
        const dirs = root.watchDirs.map(d => "'" + d.replace(/'/g, "'\\''") + "'").join(" ");
        return "found=0\n" + "for d in " + dirs + "; do\n" + "  [ -d \"$d\" ] || continue\n" + "  found=1\n" + "  for f in \"$d\"/*.json; do\n" + "    [ -f \"$f\" ] || continue\n" + "    printf '\\n===dejavu===%s\\n' \"$f\"\n" + "    cat \"$f\" 2>/dev/null\n" + "    printf '\\n'\n" + "  done\n" + "done\n" + "[ \"$found\" = 1 ] || printf 'dir:missing\\n'\n";
    }

    Process {
        id: liveProc

        command: ["sh", "-c", root._liveScript()]
        running: false

        stdout: StdioCollector {
            id: liveCollector
        }

        onExited: root._ingestLive(liveCollector.text || "")
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
        root.everPolled = true;
        root.active = next.active;
        root._seen = next.seen;

        if (next.historyChanged) {
            root._fallbackHistory = next.history;
            root._recombine();
        }
        // An action just ended: its journal record is being written right now,
        // so ask for it instead of waiting out the slow timer.
        if (root.activeCount < before)
            Qt.callLater(root.refreshHistory);
    }

    // ------------------------------------------------------------- journal
    function _historyScript() {
        const files = root.historyPaths.map(f => "'" + f.replace(/'/g, "'\\''") + "'").join(" ");
        return "for f in " + files + "; do\n" + "  if [ -r \"$f\" ]; then tail -n 600 \"$f\"; exit 0; fi\n" + "done\n" + root.journalCommand + "\n";
    }

    Process {
        id: journalProc

        command: ["sh", "-c", root._historyScript()]
        running: false

        stdout: StdioCollector {
            id: journalCollector
        }

        onExited: {
            const raw = journalCollector.text || "";
            const rows = Actions.parseHistory(raw);
            // Nothing at all means neither the state file nor the journal
            // could be read; no rows from real output just means nothing has
            // finished lately.
            root.journalAvailable = raw.length > 0;
            root._journalHistory = rows;
            root._recombine();
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

    onWatchDirsChanged: {
        root._seen = {};
        root.active = [];
        Qt.callLater(root.refresh);
    }

    onHistoryLimitChanged: root._recombine()
}
