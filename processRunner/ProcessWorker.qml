import QtQuick
import Quickshell.Io

// Reusable subprocess runner: fires onDone(stdout, stderr, exitCode) exactly
// once per run(), even if the process hangs or fails to spawn at all. Ported
// from musicRunner's MpdWorker.qml, where each design choice here was found
// by live-testing against the real Quickshell runtime, not by inspection:
//
//  - Process has no default property, so it can't hold Timer children
//    directly (unlike Item) - this wraps it in an Item with the Process and
//    its Timers as siblings.
//  - A process that fails to spawn (e.g. a misconfigured binary path) never
//    fires Process.exited, so the timeout can't trust "is it still
//    running?" to know whether it needs to step in - it trusts only this
//    worker's own _exitDone/_stdoutDone bookkeeping instead.
//  - `busy` is tracked explicitly rather than aliased to proc.running: the
//    callback passed to run() fires synchronously from within onExited, at
//    which point proc.running's own change notification may not have
//    propagated yet.
//  - Each run() gets a fresh Process instance rather than reusing one: a
//    process force-killed by the timeout can still report its real exit
//    asynchronously, later, landing on whatever the *next* run() call
//    happened to be waiting on if the instance were shared. A stale signal
//    from an old instance has no live object left to fire on once
//    superseded, checked by reference identity.
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

    function run(args, onDone) {
        _onDone = onDone;
        _timedOut = false;
        _stdoutDone = false;
        _exitDone = false;
        _stdout = "";
        _stderr = "";
        busy = true;

        _proc = procComponent.createObject(root, { command: args });

        timeoutTimer.interval = timeoutMs;
        timeoutTimer.restart();
        _proc.running = true;
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
        busy = false;
        if (cb)
            cb(out, err, code);
    }

    Component {
        id: procComponent
        Process {
            id: p
            running: false

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
