import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Launcher provider backed by `nix search <flake> <regex...> --json`.
//
// getItems() is synchronous by contract, but nix search takes ~2s warm and can
// take a minute on a cold eval cache, so it never blocks: getItems() returns
// whatever is cached for the query (or a status row) and schedules the real
// search. When the process exits we push results into the cache and ask the
// launcher to re-query us via PluginService.requestLauncherUpdate().
Item {
    id: root

    readonly property string pluginId: "nixSearch"

    property var pluginService: null
    property string trigger: "nix "

    signal itemsChanged

    // Settings, mirrored from plugin data (see NixSearchSettings.qml)
    property string nixBin: "nix"
    property string flakeRef: "nixpkgs"
    property int debounceMs: 300
    property int timeoutMs: 120000
    property int maxResults: 50
    property int minChars: 2
    property string primaryAction: "copyAttr"
    property bool showProfileInstall: false

    // Async search state
    property string _pendingQuery: ""
    property string _runningQuery: ""
    property bool _timedOut: false
    property string _stdoutText: ""
    property string _stderrText: ""
    property bool _stdoutDone: false
    property bool _exitDone: false
    property int _exitCode: 0
    property bool _slow: false
    property string _errorQuery: ""
    property string _errorText: ""

    // query -> ranked entry array
    property var _cache: ({})
    property var _cacheOrder: []
    readonly property int _cacheLimit: 40

    Component.onCompleted: _loadSettings()
    onPluginServiceChanged: _loadSettings()

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId !== root.pluginId)
                return;
            root._loadSettings();
            root._cacheClear();
        }
    }

    function _loadSettings() {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData(pluginId, "trigger", "nix ");
        nixBin = pluginService.loadPluginData(pluginId, "nixBin", "nix");
        flakeRef = pluginService.loadPluginData(pluginId, "flakeRef", "nixpkgs");
        debounceMs = pluginService.loadPluginData(pluginId, "debounceMs", 300);
        timeoutMs = pluginService.loadPluginData(pluginId, "timeoutSeconds", 120) * 1000;
        maxResults = pluginService.loadPluginData(pluginId, "maxResults", 50);
        minChars = pluginService.loadPluginData(pluginId, "minChars", 2);
        primaryAction = pluginService.loadPluginData(pluginId, "primaryAction", "copyAttr");
        showProfileInstall = pluginService.loadPluginData(pluginId, "showProfileInstall", false);
    }

    // ---------------------------------------------------------------- launcher

    function getItems(query) {
        const q = _normalize(query);

        if (q.length === 0) {
            _pendingQuery = "";
            return [_statusItem("search", "Search nixpkgs", "Type a package name or a word from its description")];
        }

        if (q.length < minChars) {
            _pendingQuery = "";
            return [_statusItem("keyboard", "Keep typing…", "At least " + minChars + " characters needed")];
        }

        const cached = _cacheGet(q);
        if (cached)
            return _toItems(cached, q);

        if (_errorQuery === q)
            return [_statusItem("error", "nix search failed", _errorText + "  ·  Press Enter to retry", "retry")];

        _requestSearch(q);
        return [_searchingItem(q)];
    }

    function executeItem(item) {
        if (!item)
            return;

        // A failed query is remembered so it is not retried on every keystroke;
        // selecting the error row is how the user asks for another attempt.
        if (item.action === "retry") {
            const q = _errorQuery;
            _errorQuery = "";
            _errorText = "";
            if (q)
                _requestSearch(q);
            _notify();
            return;
        }

        if (!item.nixEntry)
            return;
        _invoke(primaryAction, item.nixEntry);
    }

    function getContextMenuActions(item) {
        if (!item || !item.nixEntry)
            return [];

        const entry = item.nixEntry;
        const actions = [
            {
                icon: "content_copy",
                text: "Copy attribute (" + entry.attr + ")",
                action: () => root._invoke("copyAttr", entry)
            },
            {
                icon: "content_paste_go",
                text: "Copy installable (" + root._installable(entry) + ")",
                action: () => root._invoke("copyInstallable", entry)
            },
            {
                icon: "play_arrow",
                text: "Run without installing",
                action: () => root._invoke("run", entry)
            },
            {
                icon: "open_in_new",
                text: "Open on search.nixos.org",
                action: () => root._invoke("openWeb", entry)
            }
        ];

        if (showProfileInstall) {
            actions.push({
                icon: "download",
                text: "Install to user profile",
                action: () => root._invoke("profileAdd", entry)
            });
        }

        return actions;
    }

    // ------------------------------------------------------------------ search

    function _requestSearch(q) {
        _pendingQuery = q;
        debounceTimer.interval = Math.max(0, debounceMs);
        debounceTimer.restart();
    }

    // A cold nixpkgs eval cache makes the first run take ~1 minute, and that run
    // is what populates the cache for every later query. Killing it to start a
    // newer query would throw that work away, so an in-flight search is always
    // allowed to finish and the newest pending query runs right after.
    function _pump() {
        if (searchProcess.running)
            return;

        const q = _pendingQuery;
        if (!q || q.length < minChars)
            return;
        if (_cacheGet(q))
            return;
        if (_errorQuery === q)
            return;

        _launch(q);
    }

    function _launch(q) {
        _runningQuery = q;
        _timedOut = false;
        _stderrText = "";
        _stdoutDone = false;
        _exitDone = false;
        _exitCode = 0;
        _slow = false;

        searchProcess.queryForRun = q;
        searchProcess.command = _buildCommand(q);
        searchProcess.running = true;

        slowTimer.restart();
        timeoutTimer.interval = Math.max(5000, timeoutMs);
        timeoutTimer.restart();
    }

    function _buildCommand(q) {
        let command = [nixBin, "search", flakeRef];

        const terms = q.split(/\s+/);
        for (let i = 0; i < terms.length; i++) {
            if (terms[i].length > 0)
                command.push(_escapeRegex(terms[i]));
        }

        // nix search matches each argument as a regex; the query is plain text
        // as far as the user is concerned, so metacharacters are literal.
        return command.concat(["--json", "--extra-experimental-features", "nix-command flakes"]);
    }

    function _escapeRegex(text) {
        return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    Timer {
        id: debounceTimer
        interval: 300
        repeat: false
        onTriggered: root._pump()
    }

    Timer {
        id: slowTimer
        interval: 4000
        repeat: false
        onTriggered: {
            if (!searchProcess.running)
                return;
            root._slow = true;
            root._notify();
        }
    }

    Timer {
        id: timeoutTimer
        interval: 120000
        repeat: false
        onTriggered: {
            if (!searchProcess.running)
                return;
            root._timedOut = true;
            searchProcess.running = false;
        }
    }

    Process {
        id: searchProcess

        property string queryForRun: ""

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

    // Backstop for the case where the process exits but its stdout stream never
    // reports closing: without this the row would sit on "Searching…" until the
    // next keystroke happened to kick the queue along.
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

    // stdout close and process exit arrive in no guaranteed order, so results
    // are only assembled once both have landed.
    function _maybeFinalize() {
        if (!_stdoutDone || !_exitDone)
            return;

        slowTimer.stop();
        timeoutTimer.stop();

        const q = searchProcess.queryForRun;
        _runningQuery = "";
        _slow = false;

        if (_timedOut) {
            _fail(q, "Timed out after " + Math.round(timeoutTimer.interval / 1000) + "s. The nixpkgs eval cache may still be building — try again.");
        } else if (_exitCode !== 0) {
            _fail(q, _firstErrorLine(_stderrText) || ("nix exited with code " + _exitCode));
        } else {
            try {
                _cachePut(q, _rank(_parse(_stdoutText), q));
                if (_errorQuery === q) {
                    _errorQuery = "";
                    _errorText = "";
                }
            } catch (e) {
                _fail(q, "Could not parse nix search output: " + e.message);
            }
        }

        _stdoutText = "";
        _notify();
        _pump();
    }

    function _fail(q, message) {
        _errorQuery = q;
        _errorText = message;
    }

    function _firstErrorLine(text) {
        if (!text)
            return "";
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line.length > 0 && line.indexOf("evaluating '") !== 0)
                return line.length > 300 ? line.substring(0, 300) + "…" : line;
        }
        return "";
    }

    function _parse(text) {
        if (!text || text.trim().length === 0)
            return [];

        const parsed = JSON.parse(text);
        const entries = [];
        for (const key in parsed) {
            const value = parsed[key] || {};
            entries.push({
                attr: _shortAttr(key),
                fullAttr: key,
                pname: value.pname || "",
                version: value.version || "",
                description: value.description || ""
            });
        }
        return entries;
    }

    // "legacyPackages.x86_64-linux.firefox" -> "firefox", which is both what
    // goes in configuration.nix and what `nixpkgs#...` expects.
    function _shortAttr(key) {
        const parts = key.split(".");
        if (parts.length >= 3 && (parts[0] === "legacyPackages" || parts[0] === "packages"))
            return parts.slice(2).join(".");
        return key;
    }

    function _rank(entries, q) {
        const terms = q.toLowerCase().split(/\s+/).filter(t => t.length > 0);

        for (let i = 0; i < entries.length; i++) {
            const entry = entries[i];
            const attr = entry.attr.toLowerCase();
            const pname = entry.pname.toLowerCase();
            const description = entry.description.toLowerCase();

            // "haskellPackages.terminal" is a library inside a language
            // ecosystem, not something anyone launches. Those sort below every
            // top-level attribute regardless of how well they match, which
            // costs nothing when the query is itself scoped (all results are
            // then in the same tier).
            const dot = attr.lastIndexOf(".");
            const leaf = dot >= 0 ? attr.substring(dot + 1) : attr;

            let score = 0;
            for (let t = 0; t < terms.length; t++) {
                const term = terms[t];
                if (leaf === term)
                    score += 1000;
                else if (pname === term)
                    score += 800;
                else if (leaf.indexOf(term) === 0)
                    score += 400;
                else if (pname.indexOf(term) === 0)
                    score += 300;
                else if (leaf.indexOf(term) >= 0)
                    score += 150;
                else if (pname.indexOf(term) >= 0)
                    score += 120;

                if (description.indexOf(term) >= 0)
                    score += 40;
            }

            entry.tier = dot >= 0 ? 1 : 0;
            // Shorter attributes are the ones people usually mean: prefer
            // "firefox" over "firefox-esr-140-unwrapped".
            entry.score = score - Math.min(attr.length, 60);
        }

        return entries.sort((a, b) => {
            if (a.tier !== b.tier)
                return a.tier - b.tier;
            if (b.score !== a.score)
                return b.score - a.score;
            return a.attr < b.attr ? -1 : (a.attr > b.attr ? 1 : 0);
        });
    }

    // ------------------------------------------------------------------- items

    function _toItems(entries, q) {
        const shown = Math.min(entries.length, Math.max(1, maxResults));
        const items = [];

        if (entries.length === 0)
            return [_statusItem("search_off", "No packages match \"" + q + "\"", "Searched " + flakeRef + " by name and description")];

        for (let i = 0; i < shown; i++) {
            const entry = entries[i];
            items.push({
                id: "nix:" + entry.fullAttr,
                name: entry.attr,
                icon: "material:deployed_code",
                comment: _comment(entry),
                action: "primary",
                categories: ["Nix Packages"],
                keywords: entry.pname && entry.pname !== entry.attr ? [entry.pname] : [],
                // Preserve our ranking; the launcher's own scorer would
                // otherwise drop entries that only matched the description.
                _preScored: 10000 - i,
                nixEntry: entry
            });
        }

        if (entries.length > shown) {
            items.push({
                id: "nix:more",
                name: (entries.length - shown) + " more results",
                icon: "material:more_horiz",
                comment: "Narrow the query, or raise the result limit in plugin settings",
                action: "noop",
                categories: ["Nix Packages"],
                _preScored: 901
            });
        }

        return items;
    }

    function _comment(entry) {
        const description = entry.description || "No description";
        if (entry.version)
            return entry.version + " · " + description;
        return description;
    }

    function _searchingItem(q) {
        if (_slow)
            return _statusItem("hourglass_top", "Evaluating nixpkgs…", "First search builds the eval cache and can take a minute. Later searches are fast.");
        return _statusItem("hourglass_empty", "Searching nixpkgs…", "nix search " + flakeRef + " " + q);
    }

    function _statusItem(icon, name, comment, action) {
        return {
            id: "nix:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: action || "noop",
            categories: ["Nix Packages"],
            _preScored: 10000
        };
    }

    // ----------------------------------------------------------------- actions

    function _invoke(kind, entry) {
        switch (kind) {
        case "copyAttr":
            _copy(entry.attr, "Copied attribute");
            break;
        case "copyInstallable":
            _copy(_installable(entry), "Copied installable");
            break;
        case "run":
            Quickshell.execDetached([nixBin, "run", _installable(entry)]);
            _toast("Running " + entry.attr, "nix run " + _installable(entry));
            break;
        case "openWeb":
            Qt.openUrlExternally("https://search.nixos.org/packages?type=packages&query=" + encodeURIComponent(entry.pname || entry.attr));
            break;
        case "profileAdd":
            Quickshell.execDetached([nixBin, "profile", "add", _installable(entry)]);
            _toast("Installing " + entry.attr, "nix profile add " + _installable(entry));
            break;
        }
    }

    function _installable(entry) {
        return flakeRef + "#" + entry.attr;
    }

    function _copy(text, label) {
        Quickshell.execDetached(["dms", "cl", "copy", text]);
        _toast(label, text);
    }

    function _toast(title, body) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, body);
    }

    // ------------------------------------------------------------------- cache

    function _normalize(query) {
        return (query || "").trim().replace(/\s+/g, " ");
    }

    // hasOwnProperty, not _cache[q]: a query like "constructor" would otherwise
    // hit Object.prototype and be mistaken for a cached result set.
    function _cacheGet(q) {
        return Object.prototype.hasOwnProperty.call(_cache, q) ? _cache[q] : null;
    }

    function _cachePut(q, entries) {
        const next = Object.assign({}, _cache);
        next[q] = entries;

        const order = _cacheOrder.filter(key => key !== q);
        order.push(q);
        while (order.length > _cacheLimit) {
            delete next[order.shift()];
        }

        _cache = next;
        _cacheOrder = order;
    }

    function _cacheClear() {
        _cache = ({});
        _cacheOrder = [];
        _errorQuery = "";
        _errorText = "";
        _notify();
    }

    function _notify() {
        itemsChanged();
        if (pluginService && typeof pluginService.requestLauncherUpdate === "function")
            pluginService.requestLauncherUpdate(pluginId);
    }
}
