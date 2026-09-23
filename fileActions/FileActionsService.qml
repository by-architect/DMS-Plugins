pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "actions.js" as Actions

// One poller for the whole shell. The bar widget exists once per monitor and
// the popout comes and goes, so the directory is read here, in a singleton,
// and every surface reads the same two lists off it.
//
// Finished actions are remembered here too: a status file may be deleted the
// moment its action ends, so "what just finished" only exists in memory. It is
// deliberately not persisted — after a shell restart there is nothing recent
// left to report.
Singleton {
    id: root

    readonly property string pluginId: "fileActions"

    // ------------------------------------------------------------ settings
    property string watchDirSetting: ""
    property int activeIntervalMs: 800
    property int idleIntervalMs: 3000
    property int historyLimit: 20
    property int staleSeconds: 45
    property bool hideWhenIdle: false

    readonly property string watchDir: {
        const custom = (watchDirSetting || "").trim();
        if (custom)
            return custom.replace(/\/+$/, "");
        const runtime = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp";
        return runtime + "/matrix/dejavu";
    }

    // --------------------------------------------------------------- state
    // Newest start first, so `current` is the action that most recently began.
    property var active: []
    property var history: []
    property bool dirPresent: true
    property bool everPolled: false

    readonly property var current: active.length > 0 ? active[0] : null
    readonly property int activeCount: active.length

    // file name -> { raw, lastChangeMs, phase, endedMs, action }
    property var _seen: ({})

    function clearHistory() {
        history = [];
    }

    function refresh() {
        if (!proc.running)
            proc.running = true;
    }

    // ------------------------------------------------------------ polling
    // One shell pass over the directory: a marker line, the file's name, then
    // the file itself. Each file is parsed on its own, so a half-written one
    // costs its own row for one poll rather than the whole dump.
    function _script() {
        const dir = root.watchDir.replace(/'/g, "'\\''");
        return "d='" + dir + "'\n" + "if [ -d \"$d\" ]; then printf 'dir:ok\\n'; else printf 'dir:missing\\n'; exit 0; fi\n" + "for f in \"$d\"/*; do\n" + "  [ -f \"$f\" ] || continue\n" + "  printf '\\n===dejavu===%s\\n' \"${f##*/}\"\n" + "  cat \"$f\" 2>/dev/null\n" + "  printf '\\n'\n" + "done\n";
    }

    Process {
        id: proc

        command: ["sh", "-c", root._script()]
        running: false

        stdout: StdioCollector {
            id: outCollector
        }

        onExited: root._ingest(outCollector.text || "")
    }

    Timer {
        interval: root.activeCount > 0 ? root.activeIntervalMs : root.idleIntervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // ------------------------------------------------------------ ingestion
    // The rules live in actions.js; this only moves the result into place.
    function _ingest(raw) {
        const next = Actions.ingest(root._seen, root.history, raw, {
            nowMs: Date.now(),
            staleMs: root.staleSeconds * 1000,
            historyLimit: root.historyLimit
        });

        root.dirPresent = next.dirPresent;
        root.everPolled = true;
        root.active = next.active;
        root._seen = next.seen;
        if (next.historyChanged)
            root.history = next.history;
    }

    // ------------------------------------------------------- plugin settings
    function _loadSettings() {
        watchDirSetting = PluginService.loadPluginData(pluginId, "watchDir", "");
        activeIntervalMs = PluginService.loadPluginData(pluginId, "activeIntervalMs", 800);
        idleIntervalMs = PluginService.loadPluginData(pluginId, "idleIntervalMs", 3000);
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

    onWatchDirChanged: {
        root._seen = {};
        root.active = [];
        Qt.callLater(root.refresh);
    }
}
