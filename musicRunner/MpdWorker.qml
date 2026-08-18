import QtQuick
import Quickshell.Io

// Reusable mpc subprocess runner: fires onDone(stdout, stderr, exitCode)
// exactly once per run(), even if the underlying process hangs or fails to
// spawn at all. Live-tested against the real Quickshell runtime (not just
// static analysis) through several rounds, each round catching a real bug:
//
//  - An unreachable MPD host doesn't fail fast - it can hang for a long
//    time - so every run() is bounded by a timeout.
//  - A process that fails to spawn (e.g. a misconfigured mpc path) never
//    fires Process.exited, so the timeout can't trust "is it still
//    running?" to know whether it needs to step in. It instead trusts only
//    this worker's own _exitDone/_stdoutDone bookkeeping.
//  - A process force-killed by the timeout can still report its real exit
//    asynchronously, later - after run() has already been called again for
//    a new command. A first attempt at guarding this tagged the *shared*
//    Process object with a generation number, but that tag gets overwritten
//    by the new run() before the stale signal even arrives, so the check
//    always passed. The actual fix: never reuse the Process object. Each
//    run() gets its own instance; a stale signal from an old one has no
//    live object left that the current run considers current, checked by
//    reference identity (root._proc !== the object the signal came from),
//    which can't be silently clobbered the way an int property was.
//
// Process has no default property, so it can't hold Timer children directly
// (unlike Item) - this wraps it in an Item with per-run Process instances
// and shared Timers as siblings, forwarding the small API (run/busy) callers
// need.
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
                // In case stdout is slow to report closed even though the
                // process already exited.
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

            // Detach first, so this instance's own exit/stream signals (if
            // they arrive later) find root._proc already pointing elsewhere
            // and no-op, then stop and dispose of it.
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
