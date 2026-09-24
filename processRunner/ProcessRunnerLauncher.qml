import QtQuick
import Quickshell
import qs.Services

// Launcher provider backed by `ps`. The process list doesn't depend on what's
// typed - it's the same table every time, filtered locally - so this polls
// it (throttled) rather than firing a process per keystroke, the same
// pattern tmuxRunner and musicRunner use for their own poll-driven lists.
//
// Two workers, so a slow poll never makes killing something wait, and vice
// versa: pollWorker keeps the process table warm, actionWorker handles kill
// requests (each of which is itself two chained steps - see _runKill).
//
// Only one safety rail beyond the OS's own permission checks (this never
// runs as root, so `kill` can only ever touch the user's own processes):
// killing the quickshell process running this very launcher is refused
// outright, checked fresh immediately before every kill - see
// _looksLikeQuickshell. Ending your own desktop by fat-fingering a select in
// its own launcher is the one mistake worth actively preventing; anything
// else a user's own account can kill is that user's call, the same as it
// would be from a terminal.
Item {
    id: root

    readonly property string pluginId: "processRunner"

    property var pluginService: null
    property string trigger: "kill "

    signal itemsChanged

    // Settings, mirrored from plugin data (see ProcessRunnerSettings.qml)
    property string psBin: "ps"
    property string killBin: "kill"
    property int maxResults: 15
    property int hotCpuThreshold: 50

    readonly property int _pollIntervalMs: 2000

    // Enter sends the gentle signal by default - a process can choose to
    // ignore SIGTERM, so it's a request, not a guarantee, which is exactly
    // why it's the safe default here rather than SIGKILL. Force kill is one
    // right-click away when a process won't go.
    readonly property var _processActions: [
        { id: "term", icon: "close", label: "Kill (SIGTERM)" },
        { id: "kill9", icon: "delete_forever", label: "Force kill (SIGKILL)" }
    ]

    Component.onCompleted: _loadSettings()
    onPluginServiceChanged: _loadSettings()

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId !== root.pluginId)
                return;
            root._loadSettings();
        }
    }

    function _loadSettings() {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData(pluginId, "trigger", "kill ");
        psBin = pluginService.loadPluginData(pluginId, "psBin", "ps");
        killBin = pluginService.loadPluginData(pluginId, "killBin", "kill");
        maxResults = pluginService.loadPluginData(pluginId, "maxResults", 15);
        hotCpuThreshold = pluginService.loadPluginData(pluginId, "hotCpuThreshold", 50);
    }

    // ---------------------------------------------------------------- launcher

    function getItems(query) {
        _maybePoll();

        if (_fetchError)
            return [_statusItem("error", "Could not list processes", _fetchError + "  ·  Press Enter to retry", "retry")];

        if (!_everFetched)
            return [_statusItem("hourglass_empty", "Loading processes…", "")];

        // Filtering is plain local array work over an already CPU-sorted
        // list, not a new subprocess per keystroke - unlike nixSearch or
        // musicRunner, there's no cost here to searching on every character,
        // so there's no minimum-length gate.
        const q = (query || "").trim().toLowerCase();
        const filtered = q.length === 0 ? _processes : _processes.filter(p => p.display.toLowerCase().includes(q) || p.args.toLowerCase().includes(q));
        const shown = filtered.slice(0, Math.max(1, maxResults));

        if (shown.length === 0)
            return [_statusItem("search_off", "No processes match \"" + (query || "").trim() + "\"", "")];

        return shown.map((p, i) => _toItem(p, 9000 - i));
    }

    function executeItem(item) {
        if (!item)
            return;
        if (item.action === "retry") {
            _fetchError = "";
            _lastFetchAt = 0;
            _maybePoll();
            return;
        }
        if (!item.procEntry)
            return;
        _runKill(item.procEntry, _processActions[0].id);
    }

    function getContextMenuActions(item) {
        if (!item || !item.procEntry)
            return [];

        const e = item.procEntry;
        const actions = _processActions.map(a => ({
            icon: a.icon,
            text: a.label,
            action: () => root._runKill(e, a.id)
        }));

        actions.push({
            icon: "content_copy",
            text: "Copy PID",
            action: () => {
                Quickshell.execDetached(["dms", "cl", "copy", String(e.pid)]);
                root._toast("Copied", String(e.pid));
            }
        });
        actions.push({
            icon: "content_copy",
            text: "Copy command line",
            action: () => {
                Quickshell.execDetached(["dms", "cl", "copy", e.args]);
                root._toast("Copied", e.args);
            }
        });

        return actions;
    }

    // ------------------------------------------------------------- poll chain

    property var _processes: []
    property bool _everFetched: false
    property double _lastFetchAt: 0
    property string _fetchError: ""

    function _maybePoll() {
        if (pollWorker.busy)
            return;
        const now = Date.now();
        if (_everFetched && (now - _lastFetchAt) < _pollIntervalMs)
            return;

        pollWorker.run([psBin, "-eo", "pid=,user=,pcpu=,pmem=,args=", "--sort=-pcpu", "ww"], (out, err, code) => {
            _everFetched = true;
            _lastFetchAt = Date.now();
            if (code === 0) {
                _processes = _parseProcesses(out);
                _fetchError = "";
            } else {
                _fetchError = _firstErrorLine(err) || ("ps exited with code " + code + ".");
            }
            _notify();
        });
    }

    // pid/user/%cpu/%mem are always single tokens; args is whatever's left,
    // captured as one greedy remainder rather than split on whitespace,
    // since a process can title itself with spaces in ways that would
    // otherwise misalign the columns (tmux's own server does exactly this -
    // its `comm` reads "tmux: server", live-verified on this machine, which
    // is why comm isn't requested from ps at all here - args alone already
    // covers the kernel-thread bracket fallback ("[kworker/...]") natively).
    readonly property var _lineRe: /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+([\s\S]*)$/

    function _parseProcesses(text) {
        if (!text || text.trim().length === 0)
            return [];

        const selfName = _basename(psBin);
        const out = [];
        for (const line of text.split("\n")) {
            const trimmed = line.trim();
            if (trimmed.length === 0)
                continue;
            const m = trimmed.match(_lineRe);
            if (!m)
                continue;

            const args = m[5] || "";
            const display = _displayName(args);
            // Every poll re-runs `ps` itself, and that invocation always
            // shows up measuring its own brief CPU spike - without this it
            // would misleadingly sit at or near the top of every single
            // refresh.
            if (display === selfName)
                continue;

            out.push({
                pid: m[1],
                user: m[2],
                pcpu: parseFloat(m[3]) || 0,
                pmem: parseFloat(m[4]) || 0,
                args: args,
                display: display
            });
        }
        return out;
    }

    function _displayName(args) {
        if (!args)
            return "(unknown)";
        if (args.startsWith("["))
            return args;
        const first = args.split(/\s+/)[0] || "";
        return _basename(first) || "(unknown)";
    }

    function _basename(p) {
        const slash = p.lastIndexOf("/");
        return slash >= 0 ? p.substring(slash + 1) : p;
    }

    function _firstErrorLine(text) {
        if (!text)
            return "";
        for (const line of text.split("\n")) {
            const trimmed = line.trim();
            if (trimmed.length > 0)
                return trimmed.length > 300 ? trimmed.substring(0, 300) + "…" : trimmed;
        }
        return "";
    }

    // -------------------------------------------------------------- workers

    ProcessWorker {
        id: pollWorker
    }

    ProcessWorker {
        id: actionWorker
        timeoutMs: 4000
    }

    // --------------------------------------------------------------- items

    function _toItem(p, preScored) {
        return {
            id: "proc:" + p.pid,
            name: p.display,
            icon: p.pcpu >= hotCpuThreshold ? "material:local_fire_department" : "material:memory",
            comment: p.user + " · " + p.pcpu.toFixed(1) + "% CPU · " + p.pmem.toFixed(1) + "% MEM · PID " + p.pid,
            action: "primary",
            categories: ["Processes"],
            _preScored: preScored,
            procEntry: p
        };
    }

    function _statusItem(icon, name, comment, action) {
        return {
            id: "proc:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: action || "noop",
            categories: ["Processes"],
            _preScored: 10000
        };
    }

    // -------------------------------------------------------------- actions

    // Two chained steps, both through actionWorker so a kill never races a
    // poll: first re-check the target right before touching it (the pid may
    // already have exited, and possibly been reused, since the cached list
    // was built - this is also where the quickshell self-kill guard lives),
    // then send the actual signal and report what `kill` itself says rather
    // than assuming success.
    function _runKill(entry, actionId) {
        if (actionWorker.busy) {
            _toast("Still working…", "Wait for the previous action to finish first.");
            return;
        }

        actionWorker.run([psBin, "-p", String(entry.pid), "-o", "args="], (out, err, code) => {
            const current = out.trim();
            if (code !== 0 || current.length === 0) {
                _toastError("Already gone", entry.display + " (PID " + entry.pid + ") is no longer running.");
                _lastFetchAt = 0;
                return;
            }
            if (_looksLikeQuickshell(current)) {
                _toastError("Refused", "That's quickshell — the shell running this launcher. Killing it would end your session.");
                return;
            }

            const isForce = actionId === "kill9";
            const sig = isForce ? "-9" : "-15";
            actionWorker.run([killBin, sig, String(entry.pid)], (out2, err2, code2) => {
                if (code2 === 0) {
                    if (isForce)
                        _toast("Force killed", entry.display + " (PID " + entry.pid + ")");
                    else
                        _toast("Signal sent", entry.display + " asked to exit (PID " + entry.pid + ")");
                } else {
                    _toastError("Could not kill", _firstErrorLine(err2) || ("kill exited with code " + code2 + "."));
                }
                _lastFetchAt = 0;
            });
        });
    }

    function _looksLikeQuickshell(args) {
        return args.toLowerCase().includes("quickshell");
    }

    function _toast(title, body) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, body);
    }

    function _toastError(title, body) {
        if (typeof ToastService !== "undefined" && typeof ToastService.showError === "function")
            ToastService.showError(title, body);
        else
            _toast(title, body);
    }

    function _notify() {
        itemsChanged();
        if (pluginService && typeof pluginService.requestLauncherUpdate === "function")
            pluginService.requestLauncherUpdate(pluginId);
    }
}
