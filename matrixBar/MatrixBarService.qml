pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "bar.js" as Bar

// One reader per machine for the whole shell: the bar exists once per
// screen, so every machine is read here and every bar shows the same
// numbers.
//
// The machines are matrix's own: the devices file its CLI fans out to,
// found through the installed `matrix` itself, so a machine added to the
// matrix flake shows up after the next rebuild. matrix leaves public hosts
// out (osiris), and so does this.
//
// Each machine runs scripts/probe.sh in a loop -- this one locally, the
// others over one ssh that stays open -- and sends a snapshot every few
// seconds, which bar.js turns into numbers. A connection that drops is
// opened again: at once when it had been working, later and later when it
// keeps failing, and not at all when the machine refused us (a wrong key is
// not retried every minute).
Singleton {
    id: root

    readonly property string pluginId: "matrixBar"

    // ------------------------------------------------------------ settings
    property bool shown: true
    property int computerSeconds: 5
    property int phoneSeconds: 15
    property var hiddenHosts: []
    property var collapsedHosts: []
    property real dataAllowanceGb: 0
    property string devicesFile: ""
    // The bar's width in pixels; 0 follows DankBar's thickness.
    property int barWidth: 0

    // Snapshots between two readings of the slow parts: storage, Syncthing,
    // a phone's missed calls -- every 30 s on a computer, every minute on a
    // phone. A phone's data counter is read every fifth time of those.
    readonly property int computerSlowEvery: Math.max(1, Math.round(30 / Math.max(1, computerSeconds)))
    readonly property int phoneSlowEvery: Math.max(1, Math.round(60 / Math.max(1, phoneSeconds)))

    readonly property string probeScript: Paths.strip(Qt.resolvedUrl("./scripts/probe.sh"))
    readonly property string switchScript: Paths.strip(Qt.resolvedUrl("./scripts/switch.sh"))

    // ------------------------------------------------------------- machines
    // [{ name, ip, port, user, android, self }], in the devices file's order
    property var allHosts: []
    property string localName: ""
    property string discoveryError: ""
    property bool discovering: false
    property real discoveredMs: 0

    // This machine first, then the rest as matrix lists them.
    readonly property var hosts: {
        const shown = allHosts.filter(h => root.hiddenHosts.indexOf(h.name) < 0);
        return shown.filter(h => h.self).concat(shown.filter(h => !h.self));
    }

    // tailnet address -> machine name, for who is connected over ssh
    readonly property var peerNames: {
        const out = {};
        for (const h of allHosts)
            if (h.ip)
                out[h.ip] = h.name;
        return out;
    }

    // name -> { state, detail, stats, atMs, sinceMs, failures }
    //   state: "connecting", "online", "unreachable", "auth", "hostkey", "error"
    //   stats: bar.js advance(), from the last snapshot
    property var results: ({})

    // How many bars read this. The singleton outlives them all (it stays in
    // the engine after the plugin is disabled), so the machines are only
    // read while a bar is up.
    property int consumers: 0
    readonly property bool watching: consumers > 0 && shown

    property var _streams: ({})     // name -> Process
    property var _retryAt: ({})     // name -> ms
    property var _held: ({})        // name -> true: refused us, waits for a manual retry

    // name -> { wifi|data|hotspot: { want, atMs, running, error, errorMs } }
    // A switch asked for, until the phone's snapshots show it done, or why
    // it was not.
    property var switches: ({})

    function resultFor(name) {
        return results[name] ?? null;
    }

    function isCollapsed(name) {
        return collapsedHosts.indexOf(name) >= 0;
    }

    function setCollapsed(name, on) {
        const next = collapsedHosts.filter(n => n !== name);
        if (on)
            next.push(name);
        collapsedHosts = next;
        PluginService.savePluginData(pluginId, "collapsedHosts", next);
    }

    function setShown(on) {
        shown = on;
        PluginService.savePluginData(pluginId, "shown", on);
    }

    // ---------------------------------------------------------- discovery
    // The devices file the installed matrix reads -- MATRIX_DEVICES_JSON_OVERRIDE
    // when it is set, the way matrix itself takes it -- or the one named in
    // this plugin's settings. The first line is this machine's name; a line
    // starting "error " says why there is no list.
    readonly property string _discoverScript: 'echo "host $(uname -n)"; f="$1"; ' + '[ -n "$f" ] || f="${MATRIX_DEVICES_JSON_OVERRIDE:-}"; ' + 'if [ -z "$f" ]; then m=$(command -v matrix) || { echo "error matrix is not installed (not on PATH)"; exit 0; }; ' + 'f=$(grep -ao "/nix/store/[a-z0-9]*-matrix-devices\\.json" "$(readlink -f "$m")" | head -n 1); fi; ' + '[ -n "$f" ] || { echo "error the installed matrix names no devices file"; exit 0; }; ' + 'cat "$f" 2>/dev/null || echo "error cannot read $f"'

    function discover() {
        if (discovering)
            return;
        discovering = true;
        Proc.runCommand("matrixBar.discover", ["sh", "-c", _discoverScript, "matrixbar-discover", root.devicesFile], (stdout, exitCode) => root._discovered(stdout || "", exitCode), 0, 15000);
    }

    function _discovered(text, exitCode) {
        discovering = false;
        discoveredMs = Date.now();
        const nl = text.indexOf("\n");
        const first = nl >= 0 ? text.slice(0, nl) : text;
        const rest = nl >= 0 ? text.slice(nl + 1) : "";
        if (first.indexOf("host ") === 0)
            localName = first.slice(5).trim();
        if (rest.indexOf("error ") === 0) {
            discoveryError = rest.slice(6).trim();
            return;
        }
        let list = null;
        try {
            list = JSON.parse(rest);
        } catch (e) {
            list = null;
        }
        if (!Array.isArray(list)) {
            discoveryError = exitCode === 0 ? "matrix's devices file is not a list" : "could not read matrix's devices (exit " + exitCode + ")";
            return;
        }
        discoveryError = "";
        allHosts = list.filter(d => d && d.hostName && !d.public).map(d => ({
                    "name": String(d.hostName),
                    "ip": d.ssh && d.ssh.ip ? String(d.ssh.ip) : "",
                    "port": d.ssh && d.ssh.port ? Number(d.ssh.port) : 22,
                    "user": String(d.userName || (d.user && d.user.name) || ""),
                    "android": d.system === "android",
                    "self": String(d.hostName) === localName
                }));
    }

    // ------------------------------------------------------------- streams
    readonly property var _sshOptions: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=accept-new",
        // Ride the ControlMaster ssh-link keeps open to each machine, but never
        // start one: a master forked off this ssh would hold its pipes open.
        "-o", "ControlMaster=no", "-o", "LogLevel=ERROR"]

    // $1 the probe, $2 port, $3 user@address, $4 interval, $5 slow; the rest
    // are ssh's options. A connection that rides a master already open adds
    // nothing of ours to the far end's ssh count, so the probe is told
    // whether it has a connection of its own (self=1) to leave out.
    readonly property string _wrap: 'command -v ssh >/dev/null 2>&1 || exit 91; f=$1 port=$2 dest=$3 interval=$4 slow=$5; shift 5; ' + 'self=1; ssh -O check "$@" -p "$port" "$dest" >/dev/null 2>&1 && self=0; ' + 'exec ssh "$@" -p "$port" -- "$dest" "sh -s loop interval=$interval slow=$slow self=$self port=$port" < "$f"'

    function _interval(h) {
        return Math.max(2, h.android ? root.phoneSeconds : root.computerSeconds);
    }

    // Everything that decides how a machine is read: a change to any of it
    // means a new stream.
    function _sig(h) {
        return [h.ip, h.port, h.user, h.android ? 1 : 0, h.self ? 1 : 0, _interval(h)].join("|");
    }

    function _start(h) {
        const interval = _interval(h);
        const slow = h.android ? root.phoneSlowEvery : root.computerSlowEvery;
        let command;
        let env = {
            "LC_ALL": "C"
        };
        if (h.self) {
            // Not an ssh connection, whatever the shell was started from.
            env["SSH_CONNECTION"] = "";
            command = ["sh", root.probeScript, "loop", "interval=" + interval, "slow=" + slow, "self=0", "port=" + h.port];
        } else {
            if (!h.ip) {
                _store(h.name, {
                    "state": "error",
                    "detail": "matrix has no address for it"
                });
                return;
            }
            const dest = (h.user ? h.user + "@" : "") + h.ip;
            command = ["sh", "-c", root._wrap, "matrixbar-stream", root.probeScript, String(h.port), dest, String(interval), String(slow)].concat(root._sshOptions);
        }
        const proc = streamComponent.createObject(root, {
            "host": h.name,
            "sig": _sig(h),
            "interval": interval,
            "startedMs": Date.now()
        });
        if (!proc)
            return;
        proc.environment = env;
        proc.command = command;
        const next = Object.assign({}, _streams);
        next[h.name] = proc;
        _streams = next;
        const prev = results[h.name];
        if (!prev || prev.state !== "online")
            _store(h.name, {
                "state": "connecting",
                "detail": ""
            });
        proc.running = true;
    }

    function _stop(name) {
        const proc = _streams[name];
        if (!proc)
            return;
        proc.stopping = true;
        const next = Object.assign({}, _streams);
        delete next[name];
        _streams = next;
        if (proc.running)
            proc.running = false;
        else
            proc.destroy();
    }

    // Streams for what should be watched, none for the rest.
    function _reconcile() {
        const now = Date.now();
        const want = {};
        if (watching)
            for (const h of hosts)
                want[h.name] = h;

        for (const name in _streams) {
            const h = want[name];
            if (!h || _streams[name].sig !== _sig(h))
                _stop(name);
        }

        // Forget what is no longer a machine of the matrix.
        let dropped = false;
        const kept = {};
        for (const name in results) {
            if (allHosts.some(h => h.name === name))
                kept[name] = results[name];
            else
                dropped = true;
        }
        if (dropped)
            results = kept;

        for (const name in want) {
            if (_streams[name] || _held[name])
                continue;
            if ((_retryAt[name] || 0) > now)
                continue;
            _start(want[name]);
        }
    }

    onHostsChanged: Qt.callLater(root._reconcile)
    onWatchingChanged: {
        if (watching && allHosts.length === 0 && !discovering)
            discover();
        Qt.callLater(root._reconcile);
    }
    onComputerSecondsChanged: Qt.callLater(root._reconcile)
    onPhoneSecondsChanged: Qt.callLater(root._reconcile)

    // Connect again now: everything, or one machine -- also the ones that
    // refused us, which are otherwise left alone.
    function reconnect(name) {
        const held = Object.assign({}, _held);
        const retry = Object.assign({}, _retryAt);
        for (const h of hosts) {
            if (name && h.name !== name)
                continue;
            delete held[h.name];
            delete retry[h.name];
            _stop(h.name);
        }
        _held = held;
        _retryAt = retry;
        Qt.callLater(root._reconcile);
    }

    function refresh() {
        discover();
        reconnect("");
    }

    Component {
        id: streamComponent

        Process {
            id: proc

            property string host: ""
            property string sig: ""
            property int interval: 5
            property real startedMs: 0
            property real lastLineMs: 0
            property int snapshots: 0
            property bool stopping: false
            property bool timedOut: false
            property real killAtMs: 0
            // the snapshot being read, and the last lines of stderr
            property var block: null
            property var errLines: []

            running: false

            stdout: SplitParser {
                onRead: line => root._line(proc, line)
            }

            stderr: SplitParser {
                onRead: line => {
                    if (!line)
                        return;
                    const lines = proc.errLines.concat([line]);
                    proc.errLines = lines.slice(-12);
                }
            }

            onExited: code => root._exited(proc, code)
        }
    }

    function _line(proc, line) {
        proc.lastLineMs = Date.now();
        if (line.indexOf("mx:begin") === 0) {
            proc.block = [line];
            return;
        }
        if (proc.block === null)
            return;
        proc.block.push(line);
        if (line === "mx:end") {
            const lines = proc.block;
            proc.block = null;
            _snapshot(proc, lines);
        } else if (proc.block.length > 20000) {
            // No end in sight: not a snapshot.
            proc.block = null;
        }
    }

    function _snapshot(proc, lines) {
        if (proc.stopping)
            return;
        const now = Date.now();
        const prev = results[proc.host];
        let stats;
        try {
            const snap = Bar.parseSnapshot(lines);
            stats = Bar.advance(prev && prev.stats ? prev.stats : null, snap, now, {
                "peerNames": root.peerNames,
                "dataAllowanceBytes": root.dataAllowanceGb > 0 ? root.dataAllowanceGb * 1e9 : 0
            });
        } catch (e) {
            console.warn("matrixBar: a snapshot from", proc.host, "could not be read:", e);
            return;
        }
        proc.snapshots++;
        _store(proc.host, {
            "state": "online",
            "detail": "",
            "stats": stats,
            "atMs": now,
            "sinceMs": prev && prev.state === "online" && prev.sinceMs ? prev.sinceMs : now,
            "failures": 0
        });
        _settleSwitches(proc.host);
    }

    function _exited(proc, code) {
        const name = proc.host;
        if (_streams[name] === proc) {
            const next = Object.assign({}, _streams);
            delete next[name];
            _streams = next;
        }
        if (!proc.stopping) {
            const prev = results[name] ?? {};
            const got = proc.snapshots > 0;
            let verdict = Bar.classifyExit(code, proc.errLines.join("\n"), got);
            if (proc.timedOut)
                verdict = {
                    "state": "unreachable",
                    "detail": "stopped answering"
                };
            const failures = got ? 0 : (prev.failures || 0) + 1;
            _store(name, {
                "state": verdict.state,
                "detail": verdict.detail,
                "failures": failures
            });
            if (Bar.holdsUntilManual(verdict.state)) {
                const held = Object.assign({}, _held);
                held[name] = true;
                _held = held;
            } else {
                // 3 s after a working stream ends; 10, 20, 40 s ... up to two
                // minutes while it keeps failing.
                const wait = got ? 3000 : Math.min(120000, 10000 * Math.pow(2, Math.min(4, failures - 1)));
                const retry = Object.assign({}, _retryAt);
                retry[name] = Date.now() + wait;
                _retryAt = retry;
            }
        }
        proc.destroy();
    }

    function _store(name, patch) {
        const next = Object.assign({}, results);
        next[name] = Object.assign({}, results[name] ?? {}, patch);
        results = next;
    }

    // One clock: due retries, and streams that went quiet -- a machine that
    // dropped off the network without closing anything. Three missed
    // snapshots and it is asked to stop; five seconds on, it is killed.
    Timer {
        interval: 1000
        repeat: true
        running: root.watching || Object.keys(root._streams).length > 0 || Object.keys(root.switches).length > 0
        onTriggered: {
            const now = Date.now();
            for (const name in root._streams) {
                const proc = root._streams[name];
                if (proc.killAtMs > 0) {
                    if (now > proc.killAtMs && proc.running)
                        proc.signal(9);
                    continue;
                }
                const quiet = now - Math.max(proc.lastLineMs, proc.startedMs);
                if (quiet > (proc.interval * 3 + 30) * 1000) {
                    proc.timedOut = true;
                    proc.killAtMs = now + 5000;
                    proc.running = false;
                }
            }
            for (const name in root.switches)
                root._settleSwitches(name);
            for (const name in root._retryAt) {
                if (root._retryAt[name] <= now) {
                    Qt.callLater(root._reconcile);
                    break;
                }
            }
        }
    }

    // matrix's machines change on a rebuild; look again now and then.
    Timer {
        interval: 10 * 60 * 1000
        repeat: true
        running: root.watching
        onTriggered: root.discover()
    }

    // ----------------------------------------------------------- switches
    // A phone's Wi-Fi, mobile data or hotspot, on or off: scripts/switch.sh,
    // run as root on the phone. Over ssh the way the stream goes (riding
    // ssh-link's master when there is one); when ssh cannot reach the phone
    // -- its only network was just switched off -- over adb, but only to
    // the phone with this one's serial, plugged in over USB.
    //
    // $1 the script, $2 what, $3 on|off, $4 port, $5 user@address,
    // $6 serial; the rest are ssh's options.
    readonly property string _switchWrap: 'f=$1 what=$2 want=$3 port=$4 dest=$5 serial=$6; shift 6; ' + 'run="su -c \'sh -s $what $want\'"; out="" rc=255; ' + 'if [ -n "$dest" ] && command -v ssh >/dev/null 2>&1; then out=$(ssh "$@" -p "$port" -- "$dest" "$run" < "$f" 2>&1); rc=$?; ' + '[ $rc -ne 255 ] && { printf "%s\\n" "$out"; exit $rc; }; fi; ' + 'adb=$(command -v adb) || for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" "$HOME/Opt/Android/Sdk"; do ' + '[ -n "$d" ] && [ -x "$d/platform-tools/adb" ] && { adb=$d/platform-tools/adb; break; }; done; ' + 'if [ -n "$serial" ] && [ -n "$adb" ] && "$adb" devices 2>/dev/null | grep -q "^$serial[[:space:]]*device"; then ' + 'out=$("$adb" -s "$serial" shell "$run" < "$f" 2>&1); rc=$?; printf "%s\\n" "$out"; exit $rc; fi; ' + 'printf "%s\\n" "$out"; echo "ssh cannot reach it${serial:+, and adb has no phone $serial}"; exit 255'

    readonly property int _switchWaitMs: 45000

    function switchFor(name, what) {
        const all = switches[name];
        return all ? all[what] ?? null : null;
    }

    function phoneSwitch(name, what, on) {
        const h = allHosts.find(x => x.name === name);
        if (!h || !h.android || Bar.SWITCHES.indexOf(what) < 0)
            return false;
        const r = results[name];
        const serial = r && r.stats ? r.stats.serial || "" : "";
        const dest = h.ip ? (h.user ? h.user + "@" : "") + h.ip : "";
        _setSwitch(name, what, {
            "want": on,
            "atMs": Date.now(),
            "running": true,
            "error": ""
        });
        Proc.runCommand("matrixBar.switch." + name + "." + what, ["sh", "-c", _switchWrap, "matrixbar-switch", switchScript, what, on ? "on" : "off", String(h.port), dest, serial].concat(_sshOptions), (out, code) => root._switched(name, what, on, out || "", code), 0, 40000);
        return true;
    }

    function _switched(name, what, on, out, code) {
        const sw = switchFor(name, what);
        if (!sw || sw.want !== on)
            return;
        if (code === 0) {
            _setSwitch(name, what, Object.assign({}, sw, {
                "running": false
            }));
            _settleSwitches(name);
            return;
        }
        const lines = String(out).split("\n").map(l => l.trim()).filter(l => l);
        _setSwitch(name, what, Object.assign({}, sw, {
            "running": false,
            "error": lines.length ? lines[lines.length - 1].slice(0, 160) : "it ended with " + code,
            "errorMs": Date.now()
        }));
    }

    function _setSwitch(name, what, value) {
        const next = Object.assign({}, switches);
        const mine = Object.assign({}, next[name] ?? {});
        if (value)
            mine[what] = value;
        else
            delete mine[what];
        if (Object.keys(mine).length)
            next[name] = mine;
        else
            delete next[name];
        switches = next;
    }

    // Done when the phone says so; given up on when it has not after a
    // while; an error stays a while to be read.
    function _settleSwitches(name) {
        const mine = switches[name];
        if (!mine)
            return;
        const r = results[name];
        const now = Date.now();
        for (const what in mine) {
            const sw = mine[what];
            if (sw.error) {
                if (now - sw.errorMs > 20000)
                    _setSwitch(name, what, null);
                continue;
            }
            if (sw.running)
                continue;
            if (r && r.stats && Bar.switchState(r.stats, what) === sw.want)
                _setSwitch(name, what, null);
            else if (now - sw.atMs > _switchWaitMs)
                _setSwitch(name, what, Object.assign({}, sw, {
                    "error": "the phone took it, but still shows it " + (sw.want ? "off" : "on"),
                    "errorMs": now
                }));
        }
    }

    // ------------------------------------------------------- plugin settings
    function _loadSettings() {
        shown = PluginService.loadPluginData(pluginId, "shown", true) !== false;
        computerSeconds = PluginService.loadPluginData(pluginId, "computerSeconds", 5);
        phoneSeconds = PluginService.loadPluginData(pluginId, "phoneSeconds", 15);
        const hidden = PluginService.loadPluginData(pluginId, "hiddenHosts", []);
        hiddenHosts = Array.isArray(hidden) ? hidden : [];
        const collapsed = PluginService.loadPluginData(pluginId, "collapsedHosts", []);
        collapsedHosts = Array.isArray(collapsed) ? collapsed : [];
        dataAllowanceGb = Number(PluginService.loadPluginData(pluginId, "dataAllowanceGb", 0)) || 0;
        barWidth = Number(PluginService.loadPluginData(pluginId, "barWidth", 0)) || 0;
        const file = PluginService.loadPluginData(pluginId, "devicesFile", "");
        if (file !== devicesFile) {
            devicesFile = file;
            if (discoveredMs > 0)
                discover();
        }
    }

    Component.onCompleted: _loadSettings()

    Connections {
        target: PluginService

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
        }
    }

    // ------------------------------------------------------------------ IPC
    // `dms ipc call matrixBar <command>`
    IpcHandler {
        target: "matrixBar"

        function toggle(): string {
            root.setShown(!root.shown);
            return root.shown ? "SHOWN" : "HIDDEN";
        }

        function show(): string {
            root.setShown(true);
            return "SHOWN";
        }

        function hide(): string {
            root.setShown(false);
            return "HIDDEN";
        }

        // Look for machines again, and connect to every one anew.
        function refresh(): string {
            root.refresh();
            return "reconnecting " + root.hosts.length + " machines";
        }

        function reconnect(name: string): string {
            if (!root.hosts.some(h => h.name === name))
                return "no machine called " + name;
            root.reconnect(name);
            return "reconnecting " + name;
        }

        // A phone's switch: what is wifi, data or hotspot; state on, off or
        // toggle. `dms ipc call matrixBar phone logos hotspot toggle`
        function phone(name: string, what: string, state: string): string {
            const h = root.allHosts.find(x => x.name === name);
            if (!h || !h.android)
                return "no phone called " + name;
            if (Bar.SWITCHES.indexOf(what) < 0)
                return "no switch called " + what + " (" + Bar.SWITCHES.join(", ") + ")";
            let on;
            if (state === "on" || state === "off")
                on = state === "on";
            else if (state === "toggle") {
                const r = root.results[name];
                const now = r && r.stats ? Bar.switchState(r.stats, what) : null;
                if (now === null)
                    return "not known yet whether " + what + " is on";
                on = !now;
            } else
                return "on, off or toggle, not " + state;
            root.phoneSwitch(name, what, on);
            return "switching " + what + " " + (on ? "on" : "off") + " on " + name;
        }

        // One line per machine, tab separated.
        function status(): string {
            const now = Date.now();
            const lines = ["machines: " + root.hosts.length + (root.discoveryError ? "  (" + root.discoveryError + ")" : "") + (root.watching ? "" : "  (not watching: " + (root.shown ? "no bar is up" : "hidden") + ")")];
            for (const h of root.hosts) {
                const r = root.results[h.name];
                const s = r ? r.stats : null;
                const cols = [h.name + (h.self ? " (this machine)" : ""), r ? Bar.stateLabel(r.state) : "not read yet"];
                if (s) {
                    cols.push("cpu " + Bar.percentText(s.cpu), "gpu " + Bar.percentText(s.gpu));
                    cols.push("mem " + Bar.percentText(s.mem ? s.mem.percent : -1), "swap " + Bar.percentText(s.swap ? s.swap.percent : -1));
                    for (const d of s.disks)
                        cols.push((d.label || d.mount) + " " + Bar.percentText(d.percent));
                    for (const d of s.removable)
                        cols.push(d.label + " " + Bar.percentText(d.percent));
                    if (s.battery)
                        cols.push("battery " + Bar.percentText(s.battery.level) + (s.battery.charging ? " charging" : ""));
                    if (s.ssh)
                        cols.push("ssh " + s.ssh.total);
                    if (s.sync)
                        cols.push("syncthing " + s.sync.state);
                    if (s.rsync)
                        cols.push("rsync " + s.rsync.count + "/" + s.rsync.configured);
                    if (s.backup)
                        cols.push("backup " + s.backup.count + "/" + s.backup.configured);
                    if (s.android) {
                        if (s.cell)
                            cols.push("signal " + s.cell.level + "/4 " + s.cell.rat);
                        cols.push("net " + s.net, "call " + s.call, "missed " + s.missed);
                        for (const w of Bar.SWITCHES) {
                            const on = Bar.switchState(s, w);
                            cols.push(w + " " + (on === null ? "?" : (on ? "on" : "off")));
                        }
                        if (s.data)
                            cols.push("data " + Bar.bytesText(s.data.used) + (s.data.percent >= 0 ? " " + Bar.percentText(s.data.percent) : ""));
                    }
                }
                if (r && r.detail)
                    cols.push(r.detail);
                if (r && r.atMs)
                    cols.push("read " + Bar.agoText(r.atMs, now));
                lines.push(cols.join("\t"));
            }
            return lines.join("\n");
        }
    }
}
