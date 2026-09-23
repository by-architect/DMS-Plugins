import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Launcher provider backed by `tmux list-sessions`. Unlike a search query, the
// session list doesn't depend on what's typed - it's the same command every
// time, filtered locally - so this polls it (throttled) rather than firing a
// process per keystroke, and getItems() always answers from cache.
//
// Also folds in hosts from the sshManager plugin, if installed: each host
// that has no live tmux session yet shows up as its own entry, and selecting
// it creates one that runs `ssh` as the session's command -- so a remote
// connection gets tmux's detach/reattach for free. Once that session exists,
// the host stops appearing separately; it's just a normal tmux session from
// then on, found and killed the same way as any other.
//
// Each host is also probed in the background (non-interactively, one at a
// time, throttled harder than the local list since it's a real network
// round trip) for tmux sessions already running on it -- otherwise there'd
// be no way to tell a session was already there, and this would always
// offer to start a redundant new one. See _maybeRefreshRemote below.
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

    // Hosts from sshManager, if that plugin is installed. Reading another
    // plugin's settings this way needs no special permission -- see
    // sshManager's README for the shape of a "hosts" entry.
    property var sshHosts: []

    // sshManager's daemon instance, if that plugin is enabled -- needed (not
    // just its settings) to hand back a stored password for the background,
    // non-interactive probes below. Bound reactively, same pattern as
    // sshManager's own README documents for consumers.
    readonly property var _sshDaemon: {
        const instances = pluginService?.pluginDaemonInstances ?? ({});
        return instances["sshManager"] ?? null;
    }

    // Remote tmux sessions per SSH host, discovered by actually connecting
    // (non-interactively, in the background) and asking. Keyed by host id:
    // { sessions: [...], ok: bool, checkedAt: number }. Without this, an SSH
    // host could only ever be offered as "start a new connection" -- there
    // was no way to tell whether a session was already running over there,
    // so that question always came back false.
    property var _remoteHostState: ({})
    property var _remoteProbeQueue: []
    property bool _remoteProbeInFlight: false
    property bool _remoteProbeTimedOut: false
    property double _lastRemoteProbeCycleAt: 0
    readonly property int _minRemoteProbeIntervalMs: 20000

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
            if (changedPluginId === root.pluginId) {
                root._loadSettings();
            } else if (changedPluginId === "sshManager") {
                root._loadSshHosts();
                root.itemsChanged();
            }
        }
    }

    function _loadSettings() {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData(pluginId, "trigger", "tmux ");
        tmuxBin = pluginService.loadPluginData(pluginId, "tmuxBin", "tmux");
        terminalBin = pluginService.loadPluginData(pluginId, "terminalBin", "ghostty");
        terminalArgsOverride = pluginService.loadPluginData(pluginId, "terminalArgsOverride", "");
        _loadSshHosts();
    }

    function _loadSshHosts() {
        if (!pluginService)
            return;
        const loaded = pluginService.loadPluginData("sshManager", "hosts", []);
        sshHosts = Array.isArray(loaded) ? loaded : [];
        _pruneRemoteHostState();
    }

    // Drops cached probe results for hosts that no longer exist, so a
    // removed-then-recreated host (new id) starts clean instead of somehow
    // inheriting stale sessions.
    function _pruneRemoteHostState() {
        const validIds = new Set(sshHosts.map(h => h.id));
        let changed = false;
        const pruned = {};
        for (const id in _remoteHostState) {
            if (validIds.has(id))
                pruned[id] = _remoteHostState[id];
            else
                changed = true;
        }
        if (changed)
            _remoteHostState = pruned;
    }

    // ---------------------------------------------------------------- launcher

    function getItems(query) {
        _maybeRefresh();
        _maybeRefreshRemote();

        if (!_everFetched)
            return [_statusItem("hourglass_empty", "Loading tmux sessions…", "")];

        if (_fetchError)
            return [_statusItem("error", "tmux list-sessions failed", _fetchError + "  ·  Press Enter to retry", "retry")];

        const q = (query || "").trim();
        const lower = q.toLowerCase();
        let items = [];

        if (q.length === 0) {
            for (let i = 0; i < _sessions.length; i++)
                items.push(_sessionItem(_sessions[i], _sessions.length - i + 8000));
        } else {
            const matched = _sessions.filter(s => s.name.toLowerCase().includes(lower));
            const ranked = _rank(matched, lower);
            for (let i = 0; i < ranked.length; i++)
                items.push(_sessionItem(ranked[i], ranked.length - i + 8000));
        }

        // SSH hosts whose session is already running locally are just that
        // tmux session above -- attaching to it needs no special-casing, so
        // they are skipped here to avoid listing the same destination twice.
        const liveSessionNames = new Set(_sessions.map(s => s.name));
        const hostTextMatches = h => (h.name || "").toLowerCase().includes(lower) || (h.host || "").toLowerCase().includes(lower) || (h.username || "").toLowerCase().includes(lower);
        const sshMatches = q.length === 0 ? sshHosts : sshHosts.filter(h => {
            if (hostTextMatches(h))
                return true;
            const state = _remoteHostState[h.id];
            return !!(state && state.ok && state.sessions.some(s => s.name.toLowerCase().includes(lower)));
        });
        for (let i = 0; i < sshMatches.length; i++) {
            const h = sshMatches[i];
            const state = _remoteHostState[h.id];
            const remoteSessions = (state && state.ok) ? state.sessions : [];
            const byHost = q.length === 0 || hostTextMatches(h);
            const visibleRemote = byHost ? remoteSessions : remoteSessions.filter(s => s.name.toLowerCase().includes(lower));

            for (let j = 0; j < visibleRemote.length; j++) {
                const rs = visibleRemote[j];
                const remoteLocalName = _sshRemoteSessionName(h, rs.name);
                if (liveSessionNames.has(remoteLocalName))
                    continue;
                items.push(_sshRemoteItem(h, rs, remoteLocalName));
            }

            const sessionName = _sshSessionName(h);
            if (!liveSessionNames.has(sessionName))
                items.push(_sshItem(h, sessionName, remoteSessions.length > 0 ? "new" : undefined));
        }

        if (q.length > 0) {
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
            return;
        }
        if (item.action === "ssh-connect" && item.sshEntry) {
            _connectSsh(item.sshEntry, item.sshSessionName);
            return;
        }
        if (item.action === "ssh-attach-remote" && item.sshEntry) {
            _connectSshRemoteSession(item.sshEntry, item.remoteSessionName, item.sshSessionName);
        }
    }

    function getContextMenuActions(item) {
        if (!item)
            return [];

        if ((item.action === "ssh-connect" || item.action === "ssh-attach-remote") && item.sshEntry) {
            const h = item.sshEntry;
            const dest = h.username ? (h.username + "@" + h.host) : h.host;
            return [{
                icon: "content_copy",
                text: "Copy connection string",
                action: () => {
                    Quickshell.execDetached(["dms", "cl", "copy", "ssh://" + dest + (h.port && h.port !== "22" ? ":" + h.port : "")]);
                    root._toast("Copied", dest);
                }
            }];
        }

        if (item.action !== "attach" || !item.tmuxEntry)
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

    // --------------------------------------------------------- remote fetch
    //
    // Probes each configured SSH host, in the background, for its own live
    // tmux sessions -- non-interactively, one host at a time, only while the
    // launcher is actually in use (driven from getItems, same as the local
    // list) and no more often than _minRemoteProbeIntervalMs, since each
    // check is a real network round trip rather than a local command.
    //
    // Key-based hosts connect with BatchMode=yes -- never prompt, fail fast
    // if the agent or default identity doesn't work. Password hosts need an
    // actual secret to authenticate without a terminal to prompt in, so
    // they're only probed when sshManager has one stored for that host;
    // getPassword() is what hands it over, and it's passed to `sshpass -e`
    // through the process environment rather than argv, exactly as
    // sshManager's README asks consumers to. Either way, anything short of
    // success (offline host, bad key, no stored password, sshpass missing)
    // just leaves that host without remote sessions listed -- it silently
    // falls back to the plain "connect" entry rather than surfacing an error
    // per host.
    function _maybeRefreshRemote() {
        if (_remoteProbeInFlight || _remoteProbeQueue.length > 0)
            return;
        if (sshHosts.length === 0)
            return;
        const now = Date.now();
        if (_lastRemoteProbeCycleAt !== 0 && (now - _lastRemoteProbeCycleAt) < _minRemoteProbeIntervalMs)
            return;
        _lastRemoteProbeCycleAt = now;
        _startRemoteProbeCycle();
    }

    function _startRemoteProbeCycle() {
        if (_remoteProbeInFlight)
            return;
        _pruneRemoteHostState();
        _remoteProbeQueue = sshHosts.map(h => h.id);
        _advanceRemoteProbeQueue();
    }

    function _advanceRemoteProbeQueue() {
        if (_remoteProbeInFlight)
            return;
        if (_remoteProbeQueue.length === 0)
            return;
        const hostId = _remoteProbeQueue.shift();
        const h = sshHosts.find(x => x.id === hostId);
        if (!h) {
            _advanceRemoteProbeQueue();
            return;
        }
        _probeHost(h);
    }

    // A host this cycle can't probe (no stored password, sshpass check will
    // decide the rest) just keeps whatever state it already had and moves on.
    function _skipProbeHost(hostId) {
        if (!_remoteHostState[hostId]) {
            const nextState = Object.assign({}, _remoteHostState);
            nextState[hostId] = {
                sessions: [],
                ok: false,
                checkedAt: 0
            };
            _remoteHostState = nextState;
        }
        _advanceRemoteProbeQueue();
    }

    function _probeHost(h) {
        const password = h.authMethod === "password" ? ((h.hasPassword && root._sshDaemon) ? root._sshDaemon.getPassword(h.id) : "") : "";
        if (h.authMethod === "password" && !password) {
            _skipProbeHost(h.id);
            return;
        }

        _remoteProbeInFlight = true;
        _remoteProbeTimedOut = false;
        remoteProbeProcess._hostId = h.id;
        remoteProbeProcess._stdoutBuf = "";
        remoteProbeProcess._stdoutDone = false;
        remoteProbeProcess._exitDone = false;
        remoteProbeProcess._exitCode = 0;

        const connOpts = ["-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1", "-o", "StrictHostKeyChecking=accept-new"];
        const remoteCmd = "tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null";

        if (h.authMethod === "password") {
            const argv = _sshArgsWithOptions(h, connOpts.concat(["-o", "NumberOfPasswordPrompts=1"]));
            // sshpass may not be installed -- checked here rather than
            // required up front, since remote session discovery is a bonus
            // on top of the plain connect entry, not something to gate the
            // whole plugin on.
            remoteProbeProcess.environment = {
                "SSHPASS": password
            };
            remoteProbeProcess.command = ["sh", "-c", 'command -v sshpass >/dev/null 2>&1 && exec sshpass -e "$@" || exit 90', "sh"].concat(argv, [remoteCmd]);
        } else {
            remoteProbeProcess.environment = {};
            const argv = _sshArgsWithOptions(h, connOpts.concat(["-o", "BatchMode=yes"]));
            remoteProbeProcess.command = argv.concat([remoteCmd]);
        }

        remoteProbeTimeoutTimer.restart();
        remoteProbeProcess.running = true;
    }

    Timer {
        id: remoteProbeTimeoutTimer
        interval: 7000
        repeat: false
        onTriggered: {
            if (!remoteProbeProcess.running)
                return;
            root._remoteProbeTimedOut = true;
            remoteProbeProcess.running = false;
        }
    }

    Process {
        id: remoteProbeProcess
        running: false

        property string _hostId: ""
        property string _stdoutBuf: ""
        property bool _stdoutDone: false
        property bool _exitDone: false
        property int _exitCode: 0

        stdout: StdioCollector {
            onStreamFinished: {
                remoteProbeProcess._stdoutBuf = text;
                remoteProbeProcess._stdoutDone = true;
                root._maybeFinalizeRemoteProbe();
            }
        }

        stderr: StdioCollector {}

        onExited: exitCode => {
            remoteProbeProcess._exitCode = exitCode;
            remoteProbeProcess._exitDone = true;
            root._maybeFinalizeRemoteProbe();
            remoteProbeFinalizeGuard.restart();
        }
    }

    // Same backstop as the local list fetch, for the same reason.
    Timer {
        id: remoteProbeFinalizeGuard
        interval: 250
        repeat: false
        onTriggered: {
            if (!remoteProbeProcess._exitDone || remoteProbeProcess._stdoutDone)
                return;
            remoteProbeProcess._stdoutDone = true;
            root._maybeFinalizeRemoteProbe();
        }
    }

    function _maybeFinalizeRemoteProbe() {
        if (!remoteProbeProcess._stdoutDone || !remoteProbeProcess._exitDone)
            return;

        remoteProbeTimeoutTimer.stop();

        const hostId = remoteProbeProcess._hostId;
        const timedOut = _remoteProbeTimedOut;
        const exitCode = remoteProbeProcess._exitCode;
        const text = remoteProbeProcess._stdoutBuf;

        // Same 0-or-1 rule as the local fetch: 1 with no output just means
        // no server / no sessions on that host, not a failure. Anything else
        // (auth failure, unreachable, missing sshpass) leaves it un-probed.
        let ok = false;
        let sessions = [];
        if (!timedOut && (exitCode === 0 || exitCode === 1)) {
            try {
                sessions = _parse(text);
                ok = true;
            } catch (e) {
                ok = false;
            }
        }

        const nextState = Object.assign({}, _remoteHostState);
        nextState[hostId] = {
            sessions: sessions,
            ok: ok,
            checkedAt: Date.now()
        };
        _remoteHostState = nextState;

        remoteProbeProcess._stdoutBuf = "";
        _remoteProbeInFlight = false;
        _notify();
        _advanceRemoteProbeQueue();
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

    // variant "new" is used when this host already has live remote sessions
    // listed above it, so the entry reads as "start another one" rather than
    // the only way to reach that host.
    function _sshItem(h, sessionName, variant) {
        const dest = h.username ? (h.username + "@" + h.host) : h.host;
        const portSuffix = h.port && h.port !== "22" ? ":" + h.port : "";
        const isNew = variant === "new";
        return {
            id: "tmux:ssh:" + h.id + (isNew ? ":new" : ""),
            name: isNew ? "New session on " + (h.name || dest) : (h.name || dest),
            icon: "material:vpn_key",
            comment: isNew ? "Starts another tmux session on " + dest + portSuffix : dest + portSuffix + " · SSH host, opens in a new tmux session",
            action: "ssh-connect",
            categories: ["SSH Hosts"],
            _preScored: isNew ? 6900 : 7000,
            sshEntry: h,
            sshSessionName: sessionName
        };
    }

    // A tmux session that's already running on the remote host itself,
    // found by the background probe below. Selecting it wraps the same
    // ssh-inside-tmux pattern as _sshItem, but tells the remote tmux to
    // attach to this specific session instead of opening a bare shell.
    function _sshRemoteItem(h, remoteSession, localName) {
        const dest = h.username ? (h.username + "@" + h.host) : h.host;
        const windowLabel = remoteSession.windows === "1" ? " window" : " windows";
        return {
            id: "tmux:sshsession:" + h.id + ":" + remoteSession.name,
            name: (h.name || dest) + " / " + remoteSession.name,
            icon: remoteSession.attached ? "material:desktop_windows" : "material:desktop_access_disabled",
            comment: dest + " · " + remoteSession.windows + windowLabel + (remoteSession.attached ? " · attached elsewhere" : "") + " · remote tmux session",
            action: "ssh-attach-remote",
            categories: ["SSH Hosts"],
            _preScored: 7500,
            sshEntry: h,
            remoteSessionName: remoteSession.name,
            sshSessionName: localName
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

    // Deterministic from the host so re-selecting the same host later resolves
    // to the same session instead of piling up "ssh-prod", "ssh-prod-2", ...
    function _sshSessionName(h) {
        const base = (h.name || h.host || "ssh").toString();
        return "ssh-" + base.replace(/[^a-zA-Z0-9_-]/g, "-");
    }

    // Same idea, but for one specific remote session on that host, so
    // reselecting *that* session resolves to the same local wrapper too.
    function _sshRemoteSessionName(h, remoteName) {
        const base = (h.name || h.host || "ssh").toString();
        const remote = (remoteName || "").toString();
        return "ssh-" + base.replace(/[^a-zA-Z0-9_-]/g, "-") + "-" + remote.replace(/[^a-zA-Z0-9_-]/g, "-");
    }

    function _sshArgsWithOptions(h, extraOpts) {
        const argv = ["ssh"].concat(extraOpts || []);
        if (h.port && h.port !== "22")
            argv.push("-p", h.port);
        if (h.authMethod === "key" && h.identityFile)
            argv.push("-i", Paths.expandTilde(h.identityFile));
        argv.push(h.username ? (h.username + "@" + h.host) : h.host);
        return argv;
    }

    function _sshArgs(h) {
        return _sshArgsWithOptions(h, []);
    }

    // Single-quotes a string for a POSIX shell, e.g. for a remote session
    // name that lands inside a command line ssh hands to the far end.
    function _shQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function _connectSsh(h, sessionName) {
        const name = sessionName || _sshSessionName(h);
        Quickshell.execDetached(_terminalPrefix().concat([tmuxBin, "new-session", "-s", name]).concat(_sshArgs(h)));
        _toast("Connecting via tmux", h.name || h.host);
        _refresh();
    }

    // Same as _connectSsh, but tells the remote host's own tmux to attach to
    // a session that the probe below already found running over there,
    // instead of opening a bare shell.
    function _connectSshRemoteSession(h, remoteSessionName, localName) {
        const name = localName || _sshRemoteSessionName(h, remoteSessionName);
        const remoteCmd = "tmux attach -t " + _shQuote(remoteSessionName);
        // -t has to precede the destination -- ssh treats everything after
        // it as the remote command line, not more of its own options.
        const argv = _sshArgsWithOptions(h, ["-t"]).concat([remoteCmd]);
        Quickshell.execDetached(_terminalPrefix().concat([tmuxBin, "new-session", "-s", name]).concat(argv));
        _toast("Attaching via tmux", (h.name || h.host) + " / " + remoteSessionName);
        _refresh();
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
