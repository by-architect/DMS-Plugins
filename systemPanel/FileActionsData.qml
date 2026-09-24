import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services
import "actions.js" as Actions

// Live file-operation state plus history, ported from the fileActions plugin:
// a live status file under $XDG_RUNTIME_DIR/matrix/{fct,dejavu} answers "what
// is running now" and is deleted the moment the action ends, so history comes
// from the event log (~/.local/state/fct.json, falling back to the journal).
// See fileActions/actions.js for the parsing rules this reuses as-is.
Item {
    id: root

    property int activeIntervalMs: 1000
    property int idleIntervalMs: 4000
    property int journalIntervalMs: 30000
    property int historyLimit: 12
    property int staleSeconds: 45

    // The shell that runs the bar does not necessarily carry XDG_RUNTIME_DIR or
    // HOME, so both scripts resolve their own paths rather than trusting QML's
    // guess (see scripts/live.sh, scripts/history.sh).
    readonly property string liveScript: Paths.strip(Qt.resolvedUrl("./scripts/live.sh"))
    readonly property string historyScript: Paths.strip(Qt.resolvedUrl("./scripts/history.sh"))

    property var active: []
    property var history: []
    property bool dirPresent: true
    property bool everPolled: false
    property bool journalAvailable: true

    readonly property int activeCount: active.length

    property var _seen: ({})
    property var _fallbackHistory: []
    property var _journalHistory: []
    property real _cutoffMs: 0

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

        command: ["sh", root.liveScript]
        running: false

        // onStreamFinished, not onExited: a short-lived script's process can
        // exit before the collector has drained its pipe.
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
        root.everPolled = true;
        root.active = next.active;
        root._seen = next.seen;

        if (next.historyChanged) {
            root._fallbackHistory = next.history;
            root._recombine();
        }
        // An action just ended; its record is already logged by the time the
        // status file is deleted, so ask for it now instead of waiting out
        // the slow journal timer.
        if (root.activeCount < before)
            Qt.callLater(root.refreshHistory);
    }

    // ----------------------------------------------------------- event log
    Process {
        id: journalProc

        command: ["sh", root.historyScript, "300"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                const raw = text || "";
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
}
