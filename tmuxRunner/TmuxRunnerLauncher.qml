import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Launcher provider backed by `tmux list-sessions`. Unlike a search query, the
// session list doesn't depend on what's typed - it's the same command every
// time, filtered locally - so this polls it (throttled) rather than firing a
// process per keystroke, and getItems() always answers from cache.
Item {
    id: root

    readonly property string pluginId: "tmuxRunner"

    property var pluginService: null
    property string trigger: "tmux "

    signal itemsChanged

    // Settings, mirrored from plugin data (see TmuxRunnerSettings.qml)
    property string tmuxBin: "tmux"
    property string terminalBin: "ghostty"
    property string terminalArgsOverride: ""

    // Known -e-style flags for common terminals. Covers the ones that need
    // something other than "-e" (foot takes none, wezterm/gnome-terminal use
    // "--"); anything unlisted falls back to "-e", which is right for most X11
    // and Wayland terminals in practice.
    readonly property var _terminalFlags: ({
        "ghostty": ["-e"],
        "kitty": ["-e"],
        "alacritty": ["-e"],
        "foot": [],
        "wezterm": ["start", "--"],
        "gnome-terminal": ["--"],
        "xterm": ["-e"],
        "konsole": ["-e"],
        "st": ["-e"],
        "terminator": ["-e"],
        "xfce4-terminal": ["-e"]
    })

    // Session cache + fetch state
    property var _sessions: []
    property bool _everFetched: false
    property bool _fetchInFlight: false
    property double _lastFetchAt: 0
    readonly property int _minRefreshIntervalMs: 1000
    property string _fetchError: ""
    property bool _timedOut: false
    property string _stdoutText: ""
    property string _stderrText: ""
    property bool _stdoutDone: false
    property bool _exitDone: false
    property int _exitCode: 0

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
        trigger = pluginService.loadPluginData(pluginId, "trigger", "tmux ");
        tmuxBin = pluginService.loadPluginData(pluginId, "tmuxBin", "tmux");
        terminalBin = pluginService.loadPluginData(pluginId, "terminalBin", "ghostty");
        terminalArgsOverride = pluginService.loadPluginData(pluginId, "terminalArgsOverride", "");
    }

    // ---------------------------------------------------------------- launcher

    function getItems(query) {
        _maybeRefresh();

        if (!_everFetched)
            return [_statusItem("hourglass_empty", "Loading tmux sessions…", "")];

        if (_fetchError)
            return [_statusItem("error", "tmux list-sessions failed", _fetchError + "  ·  Press Enter to retry", "retry")];

        const q = (query || "").trim();
        let items = [];

        if (q.length === 0) {
            for (let i = 0; i < _sessions.length; i++)
                items.push(_sessionItem(_sessions[i], _sessions.length - i + 8000));
        } else {
            const lower = q.toLowerCase();
            const matched = _sessions.filter(s => s.name.toLowerCase().includes(lower));
            const ranked = _rank(matched, lower);
            for (let i = 0; i < ranked.length; i++)
                items.push(_sessionItem(ranked[i], ranked.length - i + 8000));

            const hasExact = _sessions.some(s => s.name === q);
            if (!hasExact)
                items.push(_createItem(q));
        }

        if (items.length === 0)
            return [_statusItem("dvr", "No tmux sessions running", "Type a name after the trigger to create one")];

        return items;
    }

    function executeItem(item) {
        if (!item)
            return;

        if (item.action === "retry") {
            _fetchError = "";
            _refresh();
            return;
        }
        if (item.action === "attach" && item.tmuxEntry) {
            _attach(item.tmuxEntry.name);
            return;
        }
        if (item.action === "create" && item.sessionName) {
            _create(item.sessionName);
        }
    }

    function getContextMenuActions(item) {
        if (!item || item.action !== "attach" || !item.tmuxEntry)
            return [];

        const entry = item.tmuxEntry;
        return [
            {
                icon: "content_copy",
                text: "Copy session name",
                action: () => {
                    Quickshell.execDetached(["dms", "cl", "copy", entry.name]);
                    root._toast("Copied", entry.name);
                }
            },
            {
                icon: "delete",
                text: "Kill session",
                action: () => {
                    Quickshell.execDetached([root.tmuxBin, "kill-session", "-t", entry.name]);
                    root._toast("Killed session", entry.name);
                    root._refresh();
                }
            }
        ];
    }

    // ------------------------------------------------------------------ fetch

    function _maybeRefresh() {
        if (_fetchInFlight)
            return;
        const now = Date.now();
        if (_everFetched && (now - _lastFetchAt) < _minRefreshIntervalMs)
            return;
        _refresh();
    }

    function _refresh() {
        if (_fetchInFlight)
            return;
        _fetchInFlight = true;
        _timedOut = false;
        _stdoutText = "";
        _stderrText = "";
        _stdoutDone = false;
        _exitDone = false;
        _exitCode = 0;

        listProcess.command = [tmuxBin, "list-sessions", "-F", "#{session_name}|#{session_windows}|#{session_attached}"];
        listProcess.running = true;
        timeoutTimer.restart();
    }

    Timer {
        id: timeoutTimer
        interval: 5000
        repeat: false
        onTriggered: {
            if (!listProcess.running)
                return;
            root._timedOut = true;
            listProcess.running = false;
        }
    }

    Process {
        id: listProcess
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                root._stdoutText = text;
                root._stdoutDone = true;
                root._maybeFinalize();
            }
        }

        stderr: StdioCollector {
            onStreamFinished: root._stderrText = text
        }

        onExited: exitCode => {
            root._exitCode = exitCode;
            root._exitDone = true;
            root._maybeFinalize();
            finalizeGuard.restart();
        }
    }

    // Backstop in case stdout never reports closing even though the process
    // already exited (mirrors the same edge case in the nixSearch plugin).
    Timer {
        id: finalizeGuard
        interval: 250
        repeat: false
        onTriggered: {
            if (!root._exitDone || root._stdoutDone)
                return;
            root._stdoutDone = true;
            root._maybeFinalize();
        }
    }

    function _maybeFinalize() {
        if (!_stdoutDone || !_exitDone)
            return;

        timeoutTimer.stop();
        _fetchInFlight = false;
        _lastFetchAt = Date.now();
        _everFetched = true;

        // Exit code 1 with no server running is a normal "zero sessions"
        // state, not a failure - tmux uses it for both "no server" and
        // genuine errors, so the message (not just the code) decides.
        if (_timedOut) {
            _fetchError = "tmux did not respond in time.";
        } else if (_exitCode !== 0 && _exitCode !== 1) {
            _fetchError = _firstErrorLine(_stderrText) || ("tmux exited with code " + _exitCode);
        } else {
            try {
                _sessions = _parse(_stdoutText);
                _fetchError = "";
            } catch (e) {
                _fetchError = "Could not parse tmux output: " + e.message;
            }
        }

        _stdoutText = "";
        _notify();
    }

    function _firstErrorLine(text) {
        if (!text)
            return "";
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line.length > 0)
                return line.length > 300 ? line.substring(0, 300) + "…" : line;
        }
        return "";
    }

    function _parse(text) {
        if (!text || text.trim().length === 0)
            return [];

        const lines = text.trim().split("\n");
        const sessions = [];
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line.length === 0)
                continue;
            const parts = line.split("|");
            if (parts.length < 3)
                continue;
            sessions.push({
                name: parts[0],
                windows: parts[1],
                attached: parts[2] === "1"
            });
        }
        return sessions;
    }

    function _rank(sessions, lowerQuery) {
        const scored = sessions.map(s => {
            const name = s.name.toLowerCase();
            let score = 0;
            if (name === lowerQuery)
                score = 300;
            else if (name.indexOf(lowerQuery) === 0)
                score = 200;
            else
                score = 100 - Math.min(name.length, 60);
            return {
                session: s,
                score: score
            };
        });
        scored.sort((a, b) => {
            if (b.score !== a.score)
                return b.score - a.score;
            return a.session.name < b.session.name ? -1 : (a.session.name > b.session.name ? 1 : 0);
        });
        return scored.map(e => e.session);
    }

    // ------------------------------------------------------------------- items

    function _sessionItem(session, preScored) {
        const windowLabel = session.windows === "1" ? " window" : " windows";
        return {
            id: "tmux:" + session.name,
            name: session.name,
            icon: session.attached ? "material:desktop_windows" : "material:desktop_access_disabled",
            comment: session.windows + windowLabel + (session.attached ? " · attached elsewhere" : ""),
            action: "attach",
            categories: ["Tmux Sessions"],
            _preScored: preScored,
            tmuxEntry: session
        };
    }

    function _createItem(name) {
        return {
            id: "tmux:create:" + name,
            name: "Create \"" + name + "\"",
            icon: "material:add",
            comment: "Start a new tmux session named \"" + name + "\"",
            action: "create",
            categories: ["Tmux Sessions"],
            _preScored: 8000,
            sessionName: name
        };
    }

    function _statusItem(icon, name, comment, action) {
        return {
            id: "tmux:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: action || "noop",
            categories: ["Tmux Sessions"],
            _preScored: 10000
        };
    }

    // ----------------------------------------------------------------- actions

    function _attach(name) {
        Quickshell.execDetached(_terminalPrefix().concat([tmuxBin, "attach-session", "-t", name]));
        _toast("Attaching", name);
    }

    function _create(name) {
        Quickshell.execDetached(_terminalPrefix().concat([tmuxBin, "new-session", "-s", name]));
        _toast("Creating session", name);
    }

    function _terminalPrefix() {
        if (terminalArgsOverride && terminalArgsOverride.trim().length > 0)
            return [terminalBin].concat(terminalArgsOverride.trim().split(/\s+/));
        const flags = _terminalFlags[terminalBin];
        return [terminalBin].concat(flags !== undefined ? flags : ["-e"]);
    }

    function _toast(title, body) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, body);
    }

    function _notify() {
        itemsChanged();
        if (pluginService && typeof pluginService.requestLauncherUpdate === "function")
            pluginService.requestLauncherUpdate(pluginId);
    }
}
