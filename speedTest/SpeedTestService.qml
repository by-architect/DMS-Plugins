pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "speedtest.js" as Speed

// One tester for the whole shell: the bar pill exists once per monitor and
// the popout comes and goes, so tests run here and every surface shows the
// same results.
//
// A test is scripts/run.sh, which runs whichever speed test program is
// installed and prints its JSON; speedtest.js reads it. Results are kept in
// the plugin's state file, so a restart neither forgets them nor runs a test
// the moment the shell is back.
Singleton {
    id: root

    readonly property string pluginId: "speedTest"
    readonly property string runScript: Paths.strip(Qt.resolvedUrl("./scripts/run.sh"))

    // ------------------------------------------------------------ settings
    // Minutes between automatic tests; 0 runs one only when asked.
    property int intervalMinutes: 60
    property string tool: "auto"
    property string pillShows: "both"
    property int slowMbps: 10

    // A failed test (offline, a server that did not answer) is tried again
    // this soon rather than a whole interval later.
    readonly property int retryMinutes: 10
    // Nothing runs this soon after the shell starts: the network may still be
    // coming up at login.
    readonly property int startupGraceMs: 90000
    readonly property int historyLimit: 48
    // A test is a download and an upload of several seconds each, plus
    // finding a server; speedtest-cli on a slow link takes a minute.
    readonly property int timeoutMs: 180000

    // --------------------------------------------------------------- state
    // Oldest first: [{ ms, down, up, ping, jitter, loss, server, location,
    // isp, ip, url, tool, network }] -- successful tests only.
    property var history: []
    readonly property var last: history.length > 0 ? history[history.length - 1] : null
    property real lastAttemptMs: 0
    property string lastError: ""
    readonly property bool lastFailed: lastError !== ""

    property bool running: false
    property real startedMs: 0
    // What set the running test off: "timer", "manual", "ipc".
    property string runReason: ""

    // Set once the service exists; see startupGraceMs.
    property real _readyMs: 0
    readonly property real nextDueMs: Speed.nextDue(intervalMinutes, lastAttemptMs, lastFailed, retryMinutes, _readyMs)

    // NetworkService knows when there is no network at all; without a
    // network backend it says nothing, and a test is simply tried.
    readonly property bool offline: NetworkService.networkAvailable && NetworkService.networkStatus === "disconnected"
    readonly property bool slow: !!last && last.down >= 0 && last.down < slowMbps

    // How many bar pills exist. A singleton outlives every one of them, so
    // the timer is tied to there being a reader; each pill counts itself in
    // on creation and out on destruction.
    property int consumers: 0
    readonly property bool watching: consumers > 0

    // ------------------------------------------------------------- running
    function networkName() {
        if (NetworkService.ethernetConnected)
            return "Ethernet";
        if (NetworkService.wifiConnected)
            return NetworkService.currentWifiSSID || "Wi-Fi";
        return "";
    }

    function run(reason) {
        if (root.running || worker.busy)
            return false;
        const network = networkName();
        root.running = true;
        root.runReason = reason || "manual";
        root.startedMs = Date.now();
        root.lastAttemptMs = root.startedMs;
        PluginService.savePluginState(root.pluginId, "lastAttemptMs", root.lastAttemptMs);
        const started = worker.run(["sh", root.runScript, root.tool], (out, err, code) => {
            root.running = false;
            const r = Speed.parseResult(out);
            if (!r) {
                root.lastError = Speed.errorLine(err, code);
                PluginService.savePluginState(root.pluginId, "lastError", root.lastError);
                if (root.runReason !== "timer")
                    ToastService.showError("Speed test failed", root.lastError);
                return;
            }
            r.ms = root.startedMs;
            r.network = network;
            root.history = root.history.concat([r]).slice(-root.historyLimit);
            root.lastError = "";
            PluginService.savePluginState(root.pluginId, "history", root.history);
            PluginService.savePluginState(root.pluginId, "lastError", "");
        });
        if (!started) {
            root.running = false;
            return false;
        }
        return true;
    }

    // Checked every half minute rather than timed to the second: a test that
    // comes due while the machine sleeps then runs soon after it wakes.
    function _tick() {
        if (!root.watching || root.running || root.offline)
            return;
        const due = root.nextDueMs;
        if (due > 0 && Date.now() >= due)
            run("timer");
    }

    Timer {
        interval: 30000
        repeat: true
        running: root.watching && root.intervalMinutes > 0
        onTriggered: root._tick()
    }

    CommandWorker {
        id: worker

        timeoutMs: root.timeoutMs
    }

    function clearHistory() {
        root.history = [];
        PluginService.savePluginState(root.pluginId, "history", []);
    }

    // ------------------------------------------------------- plugin settings
    function _setting(key, fallback, lo, hi) {
        const v = Math.round(Number(PluginService.loadPluginData(pluginId, key, fallback)));
        return isFinite(v) ? Math.max(lo, Math.min(hi, v)) : fallback;
    }

    function _loadSettings() {
        intervalMinutes = _setting("intervalMinutes", 60, 0, 1440);
        slowMbps = _setting("slowMbps", 10, 0, 10000);
        const t = PluginService.loadPluginData(pluginId, "tool", "auto");
        tool = ["auto", "ookla", "speedtest-cli", "librespeed"].indexOf(t) >= 0 ? t : "auto";
        const p = PluginService.loadPluginData(pluginId, "pillShows", "both");
        pillShows = ["both", "down", "all"].indexOf(p) >= 0 ? p : "both";
    }

    function _loadState() {
        const h = PluginService.loadPluginState(pluginId, "history", []);
        history = Array.isArray(h) ? h.filter(x => x && x.ms > 0).slice(-historyLimit) : [];
        lastAttemptMs = Number(PluginService.loadPluginState(pluginId, "lastAttemptMs", 0)) || 0;
        lastError = String(PluginService.loadPluginState(pluginId, "lastError", "") || "");
    }

    Component.onCompleted: {
        _readyMs = Date.now() + startupGraceMs;
        _loadSettings();
        _loadState();
    }

    Connections {
        target: PluginService

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
        }
    }

    // ------------------------------------------------------------------ IPC
    function statusText() {
        const now = Date.now();
        const lines = [];
        const l = root.last;
        lines.push("last:      " + (l ? Speed.mbpsText(l.down) + " down, " + Speed.mbpsText(l.up) + " up, ping " + Speed.msText(l.ping) + ", " + Speed.agoText(l.ms, now) + (l.network ? " on " + l.network : "") : "(no test yet)"));
        if (l)
            lines.push("server:    " + [l.server, l.location].filter(Boolean).join(", ") + (l.isp ? " · ISP " + l.isp : "") + " · " + l.tool);
        if (root.lastFailed)
            lines.push("failed:    " + root.lastError + " (" + Speed.agoText(root.lastAttemptMs, now) + ")");
        if (root.running)
            lines.push("running:   for " + Math.round((now - root.startedMs) / 1000) + " s (" + root.runReason + ")");
        const due = root.nextDueMs;
        lines.push("next:      " + (root.intervalMinutes <= 0 ? "only when asked" : (!root.watching ? "not scheduled: no pill on a bar" : (root.offline ? "waiting for a network" : Speed.inText(due, now) + ", every " + root.intervalMinutes + " min"))));
        lines.push("history:   " + root.history.length + " tests kept");
        return lines.join("\n");
    }

    IpcHandler {
        target: "speedTest"

        function status(): string {
            return root.statusText();
        }

        function run(): string {
            if (root.running)
                return "already running for " + Math.round((Date.now() - root.startedMs) / 1000) + " s";
            return root.run("ipc") ? "started" : "could not start";
        }

        // Tab separated, newest first: when, down, up, ping (Mbit/s, ms), network.
        function history(): string {
            return root.history.slice().reverse().map(r => [new Date(r.ms).toISOString(), r.down.toFixed(1), r.up.toFixed(1), r.ping >= 0 ? r.ping.toFixed(1) : "-", r.network || ""].join("\t")).join("\n");
        }
    }
}
