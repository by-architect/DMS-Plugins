import Quickshell.Io

// Reusable mpc subprocess runner: fires onDone(stdout, stderr, exitCode)
// exactly once per run(), even if the process hangs. Connecting to an
// unreachable MPD host doesn't fail fast - it can hang for a long time - so
// every run() is bounded by a timeout that kills it and reports exitCode -1
// instead of leaving this worker (and whatever's waiting on it) stuck
// "busy" forever with no way to recover.
Process {
    id: root

    property int timeoutMs: 6000
    readonly property bool busy: running

    property var _onDone: null
    property string _stdout: ""
    property string _stderr: ""
    property bool _stdoutDone: false
    property bool _exitDone: false
    property int _exitCode: 0
    property bool _timedOut: false

    running: false

    stdout: StdioCollector {
        onStreamFinished: {
            root._stdout = text;
            root._stdoutDone = true;
            root._maybeDone();
        }
    }
    stderr: StdioCollector {
        onStreamFinished: root._stderr = text
    }
    onExited: exitCode => {
        timeoutTimer.stop();
        root._exitCode = exitCode;
        root._exitDone = true;
        root._maybeDone();
        finalizeGuard.restart();
    }

    Timer {
        id: timeoutTimer
        repeat: false
        onTriggered: {
            if (!root.running)
                return;
            root._timedOut = true;
            root.running = false;
        }
    }

    // Backstop for the case where the killed process's stdout never reports
    // closing even though it already exited.
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

    function run(args, onDone) {
        _onDone = onDone;
        _timedOut = false;
        command = args;
        running = true;
        timeoutTimer.interval = timeoutMs;
        timeoutTimer.restart();
    }

    function _maybeDone() {
        if (!_stdoutDone || !_exitDone)
            return;
        const cb = _onDone;
        const out = _stdout;
        const err = _stderr;
        const code = _timedOut ? -1 : _exitCode;
        _onDone = null;
        _stdout = "";
        _stderr = "";
        _stdoutDone = false;
        _exitDone = false;
        _exitCode = 0;
        if (cb)
            cb(out, err, code);
    }
}
