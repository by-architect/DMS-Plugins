pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// Runs one command at a time and calls onDone(stdout, stderr, exitCode)
// exactly once per run, even when the command hangs or never starts. The same
// worker as processRunner/ProcessWorker.qml, where each of these was found by
// live testing rather than by reading:
//
//  - Process has no default property, so it cannot hold its own Timers; the
//    worker is an Item with the Process and the Timers as siblings.
//  - A command that fails to spawn (a wrong binary) never emits `exited`, so
//    the timeout trusts this worker's own bookkeeping, not proc.running.
//  - `busy` is tracked by hand: the callback runs from inside onExited, where
//    proc.running's own change may not have propagated yet.
//  - Every run gets a fresh Process, because one killed by the timeout can
//    still report its real exit later, and must find nothing listening.
//
// And every one of those Processes is destroyed again once its run is over --
// created with the worker as parent, nothing else would ever free it, and the
// list poll runs every couple of seconds while the popout is open. run() also
// refuses while busy instead of replacing the running Process, which would
// orphan it the same way.
Item {
    id: root

    property int timeoutMs: 6000
    property bool busy: false

    property var _onDone: null
    property string _stdout: ""
    property string _stderr: ""
    property bool _stdoutDone: false
    property bool _exitDone: false
    property int _exitCode: 0
    property bool _timedOut: false
    property var _proc: null

    // How many Processes exist right now; 0 whenever the worker is idle.
    // Only there so a test can watch for leaks.
    property int live: 0

    function run(args, onDone) {
        if (busy)
            return false;

        const proc = procComponent.createObject(root, {
            command: args
        });
        if (!proc)
            return false;

        _onDone = onDone;
        _timedOut = false;
        _stdoutDone = false;
        _exitDone = false;
        _stdout = "";
        _stderr = "";
        _proc = proc;
        busy = true;

        timeoutTimer.interval = timeoutMs;
        timeoutTimer.restart();
        proc.running = true;
        return true;
    }

    function _maybeDone() {
        if (!_stdoutDone || !_exitDone)
            return;
        timeoutTimer.stop();
        const cb = _onDone;
        const out = _stdout;
        const err = _stderr;
        const code = _timedOut ? -1 : _exitCode;
        _onDone = null;

        // Detached before it goes, so a late signal from it (stderr finishing
        // after stdout) finds nothing to write to. destroy() is deferred, so
        // this is safe from inside that Process's own handlers.
        const finished = _proc;
        _proc = null;
        if (finished)
            finished.destroy();
        busy = false;

        if (cb)
            cb(out, err, code);
    }

    Component {
        id: procComponent

        Process {
            id: p

            running: false

            Component.onCompleted: root.live++
            Component.onDestruction: root.live--

            stdout: StdioCollector {
                onStreamFinished: {
                    if (root._proc !== p)
                        return;
                    root._stdout = text;
                    root._stdoutDone = true;
                    root._maybeDone();
                }
            }

            stderr: StdioCollector {
                onStreamFinished: {
                    if (root._proc !== p)
                        return;
                    root._stderr = text;
                }
            }

            onExited: exitCode => {
                if (root._proc !== p)
                    return;
                root._exitCode = exitCode;
                root._exitDone = true;
                root._maybeDone();
                finalizeGuard.restart();
            }
        }
    }

    Timer {
        id: timeoutTimer

        repeat: false
        onTriggered: {
            if (root._exitDone && root._stdoutDone)
                return;
            root._timedOut = true;

            const stale = root._proc;
            root._proc = null;
            if (stale) {
                stale.running = false;
                stale.destroy();
            }

            root._exitDone = true;
            root._stdoutDone = true;
            root._maybeDone();
        }
    }

    // A process can exit without its stdout ever reporting finished; give it
    // a moment, then take what there is.
    Timer {
        id: finalizeGuard

        interval: 250
        repeat: false
        onTriggered: {
            if (!root._exitDone || root._stdoutDone)
                return;
            root._stdoutDone = true;
            root._maybeDone();
        }
    }
}
