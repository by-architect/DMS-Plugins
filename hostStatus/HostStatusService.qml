pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "hosts.js" as Hosts

// One poller for the whole shell: the bar pill exists once per monitor and
// the popout comes and goes, so the checks run here and every surface reads
// the same results.
//
// The hosts are not stored here. They are SSH Hosts' (sshManager) live list,
// read off its daemon -- or straight from its settings while the daemon is not
// up -- so adding, editing or removing a host there shows up here at once.
//
// A check is one ssh per host: scripts/remote.sh goes in on stdin, `sh -s`
// runs it on the far end, and what comes back is parsed by hosts.js.
Singleton {
    id: root

    readonly property string pluginId: "hostStatus"

    // ------------------------------------------------------------ settings
    property int pollSeconds: 60
    property bool showStorage: true
    property var excludedHosts: []

    readonly property int maxParallel: 4
    // ConnectTimeout (5 s) + the CPU sample (1 s) + df's own limit (5 s),
    // with room to spare for a slow link.
    readonly property int jobTimeoutMs: 25000

    readonly property string remoteScript: Paths.strip(Qt.resolvedUrl("./scripts/remote.sh"))

    // $1 is the probe, fed to ssh as stdin; the rest is the ssh argv. Nothing
    // secret is ever in here -- a password travels in the environment only.
    readonly property string _wrapKey: 'command -v ssh >/dev/null 2>&1 || exit 91; f=$1; shift; exec "$@" < "$f"'
    readonly property string _wrapPass: 'command -v ssh >/dev/null 2>&1 || exit 91; command -v sshpass >/dev/null 2>&1 || exit 90; f=$1; shift; exec sshpass -e "$@" < "$f"'

    // ------------------------------------------------------------- hosts
    readonly property var sshDaemon: PluginService.pluginDaemonInstances["sshManager"] ?? null
    property var _settingsHosts: []

    readonly property var allHosts: {
        const d = root.sshDaemon;
        const list = d ? d.hosts : root._settingsHosts;
        return Array.isArray(list) ? list : [];
    }
    readonly property var hosts: allHosts.filter(h => h && h.id && h.host && root.excludedHosts.indexOf(h.id) < 0)

    // --------------------------------------------------------------- state
    // host id -> { state, detail, stats, sig, checkedMs, durationMs, lastOnlineMs }
    property var results: ({})
    // host id -> true while queued or running
    property var checking: ({})

    readonly property int total: hosts.length
    readonly property int upCount: _count(r => r.state === "online")
    readonly property int downCount: _count(r => r.state !== "online")
    readonly property int checkingCount: Object.keys(checking).length
    readonly property real lastCheckedMs: {
        let latest = 0;
        for (const id in results)
            latest = Math.max(latest, results[id].checkedMs || 0);
        return latest;
    }

    // How many bar pills are reading this. A singleton outlives every one of
    // them -- it stays in the engine after the plugin is disabled or its last
    // pill removed -- so the poll is tied to there being a reader, rather
    // than ssh-ing into every host every minute until the shell restarts.
    // Each pill counts itself in on creation and out on destruction.
    property int consumers: 0
    readonly property bool watching: consumers > 0

    property var _queue: []
    property var _jobs: []

    function _count(pred) {
        let n = 0;
        for (const h of hosts) {
            const r = results[h.id];
            if (r && pred(r))
                n++;
        }
        return n;
    }

    function resultFor(id) {
        return results[id] ?? null;
    }

    function isChecking(id) {
        return checking[id] === true;
    }

    // ---------------------------------------------------------- scheduling
    // force: also retry hosts that refused us (see Hosts.holdsUntilManual).
    function refreshAll(force) {
        for (const h of hosts) {
            const r = results[h.id];
            if (!force && r && Hosts.holdsUntilManual(r.state) && r.sig === Hosts.sigOf(h))
                continue;
            _enqueue(h.id);
        }
        _pump();
    }

    function _setChecking(id, on) {
        if ((checking[id] === true) === on)
            return;
        const next = Object.assign({}, checking);
        if (on)
            next[id] = true;
        else
            delete next[id];
        checking = next;
    }

    function _enqueue(id) {
        if (checking[id])
            return;
        _queue = _queue.concat([id]);
        _setChecking(id, true);
    }

    function _pump() {
        while (_jobs.length < maxParallel && _queue.length > 0) {
            const id = _queue[0];
            _queue = _queue.slice(1);
            const h = hosts.find(x => x.id === id);
            if (!h) {
                _setChecking(id, false);
                continue;
            }
            _start(h);
        }
    }

    // A host added, edited or removed in SSH Hosts: forget what is gone, and
    // check what is new or no longer reached the way it was last time.
    function _reconcile() {
        const live = {};
        for (const h of hosts)
            live[h.id] = h;

        let dropped = false;
        const kept = {};
        for (const id in results) {
            if (live[id])
                kept[id] = results[id];
            else
                dropped = true;
        }
        if (dropped)
            results = kept;

        const queued = _queue.filter(id => !!live[id]);
        for (const id of _queue)
            if (!live[id])
                _setChecking(id, false);
        _queue = queued;

        if (!watching)
            return;
        for (const h of hosts) {
            const r = results[h.id];
            if (!r || r.sig !== Hosts.sigOf(h))
                _enqueue(h.id);
        }
        _pump();
    }

    onHostsChanged: Qt.callLater(root._reconcile)

    Timer {
        interval: Math.max(15, root.pollSeconds) * 1000
        repeat: true
        running: root.watching
        triggeredOnStart: true
        onTriggered: root.refreshAll(false)
    }

    // ---------------------------------------------------------------- jobs
    function _baseArgv(h) {
        const d = root.sshDaemon;
        if (d && typeof d.buildSshArgs === "function")
            return d.buildSshArgs(h.id);
        return Hosts.fallbackArgv(h, h.identityFile ? Paths.expandTilde(h.identityFile) : "");
    }

    function _start(h) {
        const sig = Hosts.sigOf(h);
        const viaSshpass = h.authMethod === "password";
        let password = "";

        if (viaSshpass) {
            const d = root.sshDaemon;
            password = d && typeof d.getPassword === "function" ? d.getPassword(h.id) : "";
            if (!password) {
                _store(h.id, sig, {
                    state: "nopass",
                    detail: d ? "needs key auth or sshpass -- and no password is stored for it in SSH Hosts" : "needs key auth or sshpass -- and SSH Hosts is not enabled, so its stored password cannot be read",
                    stats: null
                }, 0);
                _setChecking(h.id, false);
                return;
            }
        }

        const argv = Hosts.probeArgv(_baseArgv(h), Hosts.sshOptions(viaSshpass), "sh -s");
        if (!argv) {
            _store(h.id, sig, {
                state: "error",
                detail: "no address to connect to",
                stats: null
            }, 0);
            _setChecking(h.id, false);
            return;
        }

        const job = jobComponent.createObject(root, {
            hostId: h.id,
            sig: sig,
            viaSshpass: viaSshpass,
            startedMs: Date.now()
        });
        if (!job) {
            _setChecking(h.id, false);
            return;
        }

        // LC_ALL=C keeps ssh's messages in the English the classifier reads.
        const env = {
            "LC_ALL": "C"
        };
        if (viaSshpass)
            env["SSHPASS"] = password;
        job.environment = env;
        job.command = ["sh", "-c", viaSshpass ? root._wrapPass : root._wrapKey, "hoststatus-probe", root.remoteScript].concat(argv);
        _jobs = _jobs.concat([job]);
        job.running = true;
    }

    Component {
        id: jobComponent

        Process {
            id: job

            property string hostId: ""
            property string sig: ""
            property bool viaSshpass: false
            property real startedMs: 0
            property real exitMs: 0
            property int code: -1
            property bool crashed: false
            property bool exitSeen: false
            property bool outSeen: false
            property bool errSeen: false
            property bool timedOut: false
            property bool done: false
            property string outText: ""
            property string errText: ""

            running: false

            // A result needs all three -- the exit code and both streams --
            // and they arrive in no fixed order. waitForEnd: false keeps what
            // has arrived readable in case a stream never closes (see _sweep).
            stdout: StdioCollector {
                waitForEnd: false
                onStreamFinished: {
                    job.outText = text || "";
                    job.outSeen = true;
                    root._maybeFinish(job);
                }
            }

            stderr: StdioCollector {
                waitForEnd: false
                onStreamFinished: {
                    job.errText = text || "";
                    job.errSeen = true;
                    root._maybeFinish(job);
                }
            }

            onExited: (exitCode, exitStatus) => {
                job.code = exitCode;
                job.crashed = exitStatus !== 0;
                job.exitMs = Date.now();
                job.exitSeen = true;
                root._maybeFinish(job);
            }
        }
    }

    function _maybeFinish(job) {
        if (job && !job.done && job.exitSeen && job.outSeen && job.errSeen)
            _finish(job);
    }

    function _finish(job) {
        if (job.done)
            return;
        job.done = true;

        const verdict = Hosts.classify({
            code: job.code,
            stdout: job.outText,
            stderr: job.errText,
            timedOut: job.timedOut,
            crashed: job.crashed && !job.timedOut,
            viaSshpass: job.viaSshpass,
            timeoutSec: Math.round(root.jobTimeoutMs / 1000)
        });

        _jobs = _jobs.filter(j => j !== job);
        _setChecking(job.hostId, false);

        const h = hosts.find(x => x.id === job.hostId);
        if (h) {
            _store(job.hostId, job.sig, verdict, Date.now() - job.startedMs);
            // Edited while it was being checked: this answer is for the old
            // address, so ask again.
            if (root.watching && job.sig !== Hosts.sigOf(h))
                _enqueue(h.id);
        }

        // Every job is its own Process; destroying it here is what keeps a
        // poll every minute from piling up dead objects for the life of the
        // shell.
        job.destroy();
        _pump();
    }

    function _store(id, sig, verdict, durationMs) {
        const prev = results[id];
        const now = Date.now();
        const next = Object.assign({}, results);
        next[id] = {
            state: verdict.state,
            detail: verdict.detail,
            stats: verdict.stats,
            sig: sig,
            checkedMs: now,
            durationMs: durationMs,
            lastOnlineMs: verdict.state === "online" ? now : (prev ? prev.lastOnlineMs : 0)
        };
        results = next;
    }

    // One clock for every job. Past the deadline a job is asked to stop
    // (SIGTERM, which ssh and sshpass both honour) and counts as unreachable;
    // a few seconds later it is killed and finished regardless. A job whose
    // process has exited but whose streams stay open -- something it started
    // still holds them -- is finished with what it has.
    function _sweep() {
        const now = Date.now();
        for (const job of _jobs.slice()) {
            const age = now - job.startedMs;
            if (age > root.jobTimeoutMs + 5000) {
                job.timedOut = true;
                if (job.running)
                    job.signal(9);
                job.outText = job.outText || (job.stdout ? job.stdout.text : "") || "";
                job.errText = job.errText || (job.stderr ? job.stderr.text : "") || "";
                _finish(job);
            } else if (age > root.jobTimeoutMs && !job.timedOut) {
                job.timedOut = true;
                if (job.running)
                    job.running = false;
            } else if (job.exitSeen && !job.done && now - job.exitMs > 2000) {
                job.outText = job.outText || (job.stdout ? job.stdout.text : "") || "";
                job.errText = job.errText || (job.stderr ? job.stderr.text : "") || "";
                _finish(job);
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root._jobs.length > 0
        onTriggered: root._sweep()
    }

    // ------------------------------------------------------------- connect
    // SSH Hosts' own connect action, so the terminal and its flags are the
    // ones configured there: a daemon connect() if it ever grows one, else
    // its launcher's -- exactly what `ssh <name>` in the launcher runs.
    function openSession(id) {
        const h = allHosts.find(x => x.id === id);
        if (!h)
            return;
        const d = root.sshDaemon;
        if (d && typeof d.connect === "function") {
            d.connect(id);
            return;
        }
        const launcher = typeof PluginService.ensureLauncherInstance === "function" ? PluginService.ensureLauncherInstance("sshManager") : null;
        if (launcher && typeof launcher.executeItem === "function") {
            launcher.executeItem({
                hostEntry: h
            });
            return;
        }
        ToastService.showWarning("Cannot open a session", "Enable SSH Hosts -- its launcher is what opens the terminal");
    }

    // ------------------------------------------------------- plugin settings
    function _loadSettings() {
        pollSeconds = PluginService.loadPluginData(pluginId, "pollSeconds", 60);
        showStorage = PluginService.loadPluginData(pluginId, "showStorage", true);
        const ex = PluginService.loadPluginData(pluginId, "excludedHosts", []);
        excludedHosts = Array.isArray(ex) ? ex : [];
    }

    // Only needed while sshManager's daemon is not up; its settings hold the
    // same list the daemon would serve.
    function _loadSshHosts() {
        const list = PluginService.loadPluginData("sshManager", "hosts", []);
        _settingsHosts = Array.isArray(list) ? list : [];
    }

    Component.onCompleted: {
        _loadSettings();
        _loadSshHosts();
    }

    Connections {
        target: PluginService

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
            else if (changedPluginId === "sshManager")
                root._loadSshHosts();
        }
    }

    // `dms ipc call hostStatus status` -- one line per host, tab separated.
    IpcHandler {
        target: "hostStatus"

        function status(): string {
            const now = Date.now();
            const lines = ["hosts: " + root.total + "  online: " + root.upCount + "  down: " + root.downCount + "  checking: " + root.checkingCount + "  (" + (root.sshDaemon ? "SSH Hosts daemon" : "SSH Hosts settings") + ")"];
            for (const h of root.hosts) {
                const r = root.results[h.id];
                const s = r ? r.stats : null;
                const cols = [h.name || h.host, Hosts.destText(h), r ? Hosts.stateLabel(r.state) : (root.isChecking(h.id) ? "checking" : "not checked yet")];
                if (s) {
                    cols.push("cpu " + Hosts.percentText(s.cpuPercent));
                    cols.push("mem " + (s.mem ? Hosts.pairText(s.mem.used, s.mem.total) : "?"));
                    cols.push("swap " + (s.swap ? Hosts.pairText(s.swap.used, s.swap.total) : "?"));
                    for (const f of s.filesystems)
                        cols.push(f.mount + " " + Hosts.percentText(f.percent));
                }
                if (r && r.detail)
                    cols.push(r.detail);
                if (r)
                    cols.push("checked " + Hosts.agoText(r.checkedMs, now));
                lines.push(cols.join("\t"));
            }
            return lines.join("\n");
        }

        function refresh(): string {
            root.refreshAll(true);
            return "checking " + root.checkingCount + " of " + root.total + " hosts";
        }
    }
}
