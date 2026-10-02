pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "procstat.js" as Stat

// One sampler for the whole shell. The bar pill exists once per monitor and
// the popout comes and goes, so /proc is read here, in a singleton, and every
// surface shows the same numbers.
//
// Two rates, because the two halves cost very different amounts:
//
//   cpu, memory, load   three small procfs reads through FileView -- no
//                       process at all -- every sampleIntervalMs, while at
//                       least one pill exists
//   process list        a `ps` run, so only while a popout is actually on
//                       screen
//
// The CPU figure is the share of non-idle time between two readings of
// /proc/stat (see procstat.js), so the first reading after a start only
// primes the counters; the second follows half a second later rather than a
// whole interval.
Singleton {
    id: root

    readonly property string pluginId: "processWidget"

    // ------------------------------------------------------------ settings
    property int sampleIntervalMs: 2000
    property int processCount: 8
    property int warnPercent: 60
    property int critPercent: 85
    property bool showBar: true

    // --------------------------------------------------------------- state
    // Whole machine, 0..100; -1 until two readings exist.
    property real cpu: -1
    // [{ id, usage }] by core number; usage is -1 for a core with no earlier
    // reading yet.
    property var cores: []
    readonly property int coreCount: cores.length
    readonly property var busiest: Stat.busiest(cores)
    readonly property int level: Stat.levelFor(cpu, warnPercent, critPercent)

    // The last historyLimit readings, oldest first, for the popout's graph.
    readonly property int historyLimit: 60
    property var history: []

    property var memory: null
    property var load: null

    property var processes: []
    property string listError: ""
    property bool everListed: false
    property double listedAtMs: 0

    // The PID a kill is in flight for, so its row can say so and every kill
    // button waits for it.
    property string killingPid: ""
    readonly property bool killBusy: killingPid !== ""

    // How many bar pills exist. A singleton outlives every one of them -- it
    // stays in the engine after the plugin is disabled or its last pill
    // removed -- so sampling is tied to there being a reader. Each pill counts
    // itself in on creation and out on destruction.
    property int consumers: 0
    readonly property bool watching: consumers > 0

    // How many popouts are on screen right now. Not the same as how many
    // exist: DMS keeps a closed popout's tree loaded for a fast re-open, so
    // each popout counts itself by its own visibility.
    property int viewers: 0
    readonly property bool listing: watching && viewers > 0

    // Commands running right now: 0 whenever nothing is being listed or
    // killed, which is how a leaked Process would show.
    readonly property int liveCommands: listWorker.live + killWorker.live

    property var _prevStat: null
    property double _prevStatMs: 0

    function colorFor(value, normal) {
        const l = Stat.levelFor(value, warnPercent, critPercent);
        return l === 2 ? Theme.tempDanger : (l === 1 ? Theme.tempWarning : normal);
    }

    // ------------------------------------------------------------ sampling
    function sample() {
        statFile.reload();
        memFile.reload();
        loadFile.reload();
    }

    FileView {
        id: statFile

        path: "/proc/stat"
        printErrors: false
        onLoaded: root._ingestStat(statFile.text())
    }

    FileView {
        id: memFile

        path: "/proc/meminfo"
        printErrors: false
        onLoaded: {
            if (root.watching)
                root.memory = Stat.parseMeminfo(memFile.text());
        }
    }

    FileView {
        id: loadFile

        path: "/proc/loadavg"
        printErrors: false
        onLoaded: {
            if (root.watching)
                root.load = Stat.parseLoadavg(loadFile.text());
        }
    }

    Timer {
        interval: root.cpu < 0 ? 500 : root.sampleIntervalMs
        repeat: true
        running: root.watching
        triggeredOnStart: true
        onTriggered: root.sample()
    }

    function _ingestStat(text) {
        if (!root.watching)
            return;
        const cur = Stat.parseStat(text);
        if (!cur.all)
            return;
        // Two reads a few milliseconds apart -- the file's own preload, then
        // the timer's first tick -- describe no interval worth a number. Keep
        // the older one as the baseline and wait for the next.
        const now = Date.now();
        if (root._prevStat && now - root._prevStatMs < 250)
            return;

        const m = Stat.measure(root._prevStat, cur);
        root._prevStat = cur;
        root._prevStatMs = now;
        root.cores = m.cores;
        if (m.total >= 0) {
            root.cpu = m.total;
            root.history = root.history.concat([m.total]).slice(-root.historyLimit);
        }
    }

    // A baseline from before a pause would turn the first number after it
    // into an average over the whole pause.
    onWatchingChanged: {
        if (watching)
            return;
        root._prevStat = null;
        root.cpu = -1;
        root.cores = [];
        root.history = [];
    }

    // -------------------------------------------------------- process list
    function refreshList() {
        if (listWorker.busy)
            return;
        // "ww" so command lines come back whole: a kill compares the line it
        // sees then against this one, character for character.
        listWorker.run(["ps", "-eo", "pid=,user=,pcpu=,pmem=,args=", "--sort=-pcpu", "ww"], (out, err, code) => {
            root.everListed = true;
            if (code === 0) {
                root.processes = Stat.parseProcesses(out, {
                    limit: root.processCount,
                    skipName: "ps"
                });
                root.listError = "";
                root.listedAtMs = Date.now();
            } else if (code === -1) {
                // The worker's own timeout, which is also what a ps that could
                // not be started at all looks like.
                root.listError = "ps did not start, or did not answer in time.";
            } else {
                root.listError = Stat.firstLine(err) || ("ps exited with code " + code + ".");
            }
        });
    }

    Timer {
        interval: Math.max(1000, root.sampleIntervalMs)
        repeat: true
        running: root.listing
        triggeredOnStart: true
        onTriggered: root.refreshList()
    }

    CommandWorker {
        id: listWorker

        timeoutMs: 5000
    }

    // ---------------------------------------------------------------- kill
    //
    // processRunner's rules. The row's PID is re-checked right before the
    // signal: if nothing has it any more, or it now belongs to a different
    // command line (the listed process exited and its number was handed on),
    // nothing is sent. And quickshell -- by its own PID, or by "quickshell"
    // anywhere in the command line -- is refused outright: ending the desktop
    // from its own bar is the one mistake worth actively preventing. Anything
    // else this user may kill is theirs to kill, the same as from a terminal.
    function kill(entry, force) {
        if (!entry || !Stat.validPid(entry.pid))
            return;
        if (root.killBusy) {
            ToastService.showInfo("Still working…", "Wait for the previous kill to finish first.");
            return;
        }
        const pid = String(entry.pid);
        if (Stat.isShell(entry, Quickshell.processId)) {
            root._reportVerdict("shell", entry, "");
            return;
        }

        root.killingPid = pid;
        const started = killWorker.run(["ps", "-p", pid, "-o", "args=", "ww"], (out, err, code) => {
            const verdict = Stat.killVerdict(entry, out, code, Quickshell.processId);
            if (verdict !== "ok") {
                root.killingPid = "";
                root._reportVerdict(verdict, entry, out);
                root._refreshSoon();
                return;
            }
            // The shell's own kill, so no standalone kill binary is needed;
            // the signal and the already-validated PID arrive as arguments,
            // never as part of the script.
            const sent = killWorker.run(["sh", "-c", "kill -s \"$1\" \"$2\"", "sh", force ? "KILL" : "TERM", pid], (out2, err2, code2) => {
                root.killingPid = "";
                if (code2 === 0) {
                    if (force)
                        ToastService.showInfo("Force killed " + entry.display, "SIGKILL sent to PID " + pid);
                    else
                        ToastService.showInfo("Asked " + entry.display + " to exit", "SIGTERM sent to PID " + pid + ". Right-click the button to force it.");
                } else {
                    ToastService.showError("Could not kill " + entry.display, Stat.firstLine(err2) || ("kill exited with code " + code2 + "."));
                }
                root._refreshSoon();
            });
            if (!sent)
                root.killingPid = "";
        });
        if (!started)
            root.killingPid = "";
    }

    // For the row: the shell's own row gets no live kill button at all.
    function isShellEntry(entry) {
        return Stat.isShell(entry, Quickshell.processId);
    }

    function _reportVerdict(verdict, entry, current) {
        const who = entry.display + " (PID " + entry.pid + ")";
        if (verdict === "shell")
            ToastService.showError("Refused", "That is quickshell, the shell running this bar. Killing it would end your session.");
        else if (verdict === "gone")
            ToastService.showInfo("Already gone", who + " is no longer running.");
        else if (verdict === "reused")
            ToastService.showError("Not killed", "PID " + entry.pid + " now runs " + Stat.shorten((current || "").trim(), 80) + ", not the " + entry.display + " that was listed. The list was out of date.");
        else if (verdict === "unchecked")
            ToastService.showError("Not killed", "Could not re-check " + who + " before signalling it.");
    }

    // A process asked to exit takes a moment to do it; re-listing at once
    // would mostly show it still there.
    function _refreshSoon() {
        refreshAfterKill.restart();
    }

    Timer {
        id: refreshAfterKill

        interval: 400
        repeat: false
        onTriggered: {
            if (root.listing)
                root.refreshList();
        }
    }

    CommandWorker {
        id: killWorker

        timeoutMs: 4000
    }

    function copyPid(entry) {
        if (!entry)
            return;
        // Proc.dmsBin, not a bare "dms": the shell hands its children
        // $DMS_EXECUTABLE, but does not always have dms itself on PATH.
        Quickshell.execDetached([Proc.dmsBin, "cl", "copy", String(entry.pid)]);
        ToastService.showInfo("Copied PID " + entry.pid, entry.display);
    }

    // ------------------------------------------------------- plugin settings
    function _setting(key, fallback, lo, hi) {
        const v = Math.round(Number(PluginService.loadPluginData(pluginId, key, fallback)));
        return isFinite(v) ? Stat.clamp(v, lo, hi) : fallback;
    }

    function _loadSettings() {
        sampleIntervalMs = _setting("sampleIntervalMs", 2000, 500, 60000);
        processCount = _setting("processCount", 8, 1, 50);
        warnPercent = _setting("warnPercent", 60, 1, 100);
        critPercent = _setting("critPercent", 85, 1, 100);
        showBar = PluginService.loadPluginData(pluginId, "showBar", true) !== false;
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
    function statusText() {
        const lines = [];
        const b = root.busiest;
        lines.push("cpu:        " + (root.cpu >= 0 ? Stat.percentText(root.cpu) + " of " + root.coreCount + " cores" + (b ? ", busiest cpu" + b.id + " at " + Stat.percentText(b.usage) : "") : "(no reading yet)"));
        lines.push("load:       " + (root.load ? Stat.loadText(root.load) + "  (" + root.load.running + " running of " + root.load.tasks + " tasks)" : "(not read yet)"));
        const mem = root.memory;
        lines.push("memory:     " + (mem ? Stat.formatKb(mem.usedKb) + " of " + Stat.formatKb(mem.totalKb) + " in use" : "(not read yet)"));
        if (mem && mem.swapTotalKb > 0)
            lines.push("swap:       " + Stat.formatKb(mem.swapUsedKb) + " of " + Stat.formatKb(mem.swapTotalKb) + " in use");
        lines.push("sampling:   " + (root.watching ? "every " + root.sampleIntervalMs + " ms, " + root.consumers + (root.consumers === 1 ? " pill" : " pills") : "stopped, no pill on a bar") + "; " + root.liveCommands + " commands running");
        if (root.listError)
            lines.push("processes:  " + root.listError);
        else if (!root.everListed)
            lines.push("processes:  not listed yet (ps runs only while the popout is open)");
        else
            lines.push("processes:  " + (root.listing ? "listing now" : "as of " + Math.round((Date.now() - root.listedAtMs) / 1000) + " s ago, when the popout was last open"));
        for (let i = 0; i < root.processes.length; i++) {
            const p = root.processes[i];
            lines.push("  " + p.pid + "\t" + p.pcpu.toFixed(1) + "%\t" + p.pmem.toFixed(1) + "%\t" + p.user + "\t" + p.display);
        }
        return lines.join("\n");
    }

    IpcHandler {
        target: "processWidget"

        function status(): string {
            return root.statusText();
        }

        function refresh(): string {
            if (!root.watching)
                return "not sampling: no Process Widget pill is on a bar";
            root.sample();
            if (root.listing)
                root.refreshList();
            return "refreshing";
        }
    }
}
