import QtQuick
import Quickshell.Io

// Runs one shell command and hands its stdout to `parse`.
//
// A watchdog covers the case where the binary does not exist at all: quickshell
// logs "Process failed to start" and never emits onExited, which would otherwise
// leave the tile spinning forever.
Item {
    id: root

    property var command: []
    property var parse: null
    property var result: null
    property bool busy: false
    property bool ran: false
    property string error: ""
    property int timeoutMs: 8000

    signal updated

    function refresh() {
        if (busy)
            return;
        error = "";
        busy = true;
        proc.running = true;
        watchdog.restart();
    }

    function _finish(err, value) {
        watchdog.stop();
        busy = false;
        ran = true;
        error = err || "";
        if (!err)
            result = value;
        updated();
    }

    Process {
        id: proc

        command: root.command
        running: false

        stdout: StdioCollector {
            id: outCollector
        }

        stderr: StdioCollector {
            id: errCollector
        }

        onExited: exitCode => {
            const raw = outCollector.text || "";
            // Non-zero exit with usable stdout still parses (ss and journalctl
            // both exit non-zero on partial permission errors).
            if (exitCode !== 0 && !raw.trim()) {
                const msg = (errCollector.text || "").trim().split("\n")[0];
                root._finish(msg || ("exit " + exitCode), null);
                return;
            }
            if (!root.parse) {
                root._finish("", raw);
                return;
            }
            try {
                root._finish("", root.parse(raw));
            } catch (e) {
                root._finish("parse error: " + e.message, null);
            }
        }
    }

    Timer {
        id: watchdog

        interval: root.timeoutMs
        repeat: false
        onTriggered: {
            if (!root.busy)
                return;
            proc.running = false;
            root._finish("unavailable (no response)", null);
        }
    }
}
