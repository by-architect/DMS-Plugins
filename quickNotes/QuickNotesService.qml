import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "sync.js" as Sync

// The task list and its sync, for the life of the plugin. The daemon owns
// one of these; the window, the settings page and IPC all go through it.
//
// Nothing here waits on the network to show anything: the list on screen is
// what was last read from the server plus whatever was done here since, kept
// in the plugin's state file, so it is there the moment the shell starts.
// Syncing runs on a timer in the background -- never because the window
// opened -- and every change made here is sent on its own a moment after it
// is made, then again after a failure until the server has it.
//
// The app password is not a plugin setting: plugin settings are a plain
// JSON file next to every other plugin's (on this machine, one that
// home-manager links into the world-readable Nix store). It goes in
// ~/.local/share/DankMaterialShell/plugins/quickNotes/secrets.json, created
// mode 0600 -- or comes from a file of your own, such as an agenix or
// sops-nix secret, named in the settings.
Item {
    id: root

    readonly property string pluginId: "quickNotes"

    // ------------------------------------------------------------ settings
    property string server: ""
    property string user: ""
    property string listName: "main"
    property int syncMinutes: 5
    // How long a done task stays in the list: hours, -1 always, 0 never.
    property int keepDoneHours: 24
    property string passwordFile: ""

    // ------------------------------------------------------------ password
    readonly property string _secretsDir: Paths.strip(Paths.data) + "/plugins/quickNotes"
    readonly property string _secretsPath: _secretsDir + "/secrets.json"
    property string _storedPassword: ""
    property string _filePassword: ""
    property string passwordFileError: ""
    readonly property string password: passwordFile !== "" ? _filePassword : _storedPassword
    readonly property bool hasStoredPassword: _storedPassword !== ""
    readonly property bool configured: server !== "" && user !== "" && password !== ""

    // --------------------------------------------------------------- model
    // [{ uid, summary, description, completed, completedAt, created,
    // modified, parent, href, pending, failed }] -- see sync.js.
    property var tasks: []
    property var status: ({
            running: "",
            listUrl: "",
            listTitle: "",
            lastSyncMs: 0,
            lastError: "",
            lastErrorKind: "",
            waiting: 0,
            failed: 0,
            nextDueMs: 0
        })
    readonly property bool syncing: status.running !== ""
    readonly property string listTitle: status.listTitle || listName

    property var engine: null
    property bool _alive: true
    // A wrong password is not tried again on the timer -- Nextcloud throttles
    // an address that keeps failing to log in -- only after the settings
    // change or a sync is asked for by hand.
    property bool _authBlocked: false
    property int _failures: 0

    // ---------------------------------------------------------------- API

    // Adds a task from what was typed: the first line is its title, the rest
    // its notes. Returns its uid, or "" when nothing was typed.
    function add(text) {
        if (!engine)
            return "";
        const uid = engine.add(text);
        if (uid)
            pushSoon.restart();
        return uid;
    }

    function setDone(uid, done) {
        if (engine && engine.setDone(uid, done))
            pushSoon.restart();
    }

    // Gone from the list now, from the server Sync.UNDO_MS later.
    function remove(uid) {
        return engine ? engine.remove(uid) : false;
    }

    function canUndo() {
        return !!engine && engine.canUndo();
    }

    // The uid brought back, or "".
    function undoRemove() {
        return engine ? engine.undoRemove() : "";
    }

    function syncNow() {
        if (!engine)
            return;
        _authBlocked = false;
        engine.sync(true);
    }

    function setPassword(password) {
        _storedPassword = String(password || "");
        _writeSecrets();
        _passwordChanged();
    }

    function _passwordChanged() {
        _configure();
        _authBlocked = false;
        if (configured && !firstSync.running)
            Qt.callLater(_tick);
    }

    function statusText() {
        const s = root.status;
        const lines = [];
        lines.push("server:   " + (root.server || "(not set)") + (root.user ? " as " + root.user : ""));
        lines.push("password: " + (root.passwordFile ? "from " + root.passwordFile + (root.passwordFileError ? " (" + root.passwordFileError + ")" : "") : (root.hasStoredPassword ? "stored" : "(not set)")));
        lines.push("list:     " + root.listName + (s.listUrl ? " -> " + s.listUrl : ""));
        lines.push("tasks:    " + root.tasks.filter(t => !t.completed).length + " open, " + root.tasks.filter(t => t.completed).length + " done");
        lines.push("queue:    " + s.waiting + " waiting" + (s.failed ? ", " + s.failed + " refused" : ""));
        lines.push("synced:   " + (s.lastSyncMs ? new Date(s.lastSyncMs).toISOString() : "never") + (s.running ? " (" + s.running + " running)" : ""));
        if (s.lastError)
            lines.push("error:    " + s.lastError);
        return lines.join("\n");
    }

    // ---------------------------------------------------------- transport

    DavTransport {
        id: transport
    }

    // ------------------------------------------------------------- engine

    function _refresh() {
        if (!engine || !_alive)
            return;
        tasks = engine.tasks();
        status = engine.status();
        PluginService.savePluginState(pluginId, "cache", engine.snapshot());
        // A delete waiting out its undo time goes the moment it may.
        const due = status.nextDueMs;
        if (due > 0) {
            dueTimer.interval = Math.max(50, due - Date.now() + 50);
            dueTimer.restart();
        }
    }

    function _finished(kind, err) {
        if (!err) {
            _failures = 0;
            retryTimer.stop();
            return;
        }
        if (err.kind === "auth")
            _authBlocked = true;
        if (err.kind !== "retry")
            return;
        // 15 s, 30 s, 1 min, ... never longer than the normal interval.
        _failures++;
        retryTimer.interval = Math.min(Math.max(1, syncMinutes) * 60000, 15000 * Math.pow(2, Math.min(_failures - 1, 8)));
        retryTimer.restart();
    }

    function _configure() {
        if (!engine)
            return;
        engine.configure({
            server: server,
            user: user,
            password: password,
            listName: listName
        });
    }

    function _tick() {
        if (!engine || !configured || _authBlocked || _offline())
            return;
        engine.sync(false);
    }

    function _offline() {
        return NetworkService.networkAvailable === true && NetworkService.networkStatus === "disconnected";
    }

    Timer {
        id: pushSoon

        interval: 400
        onTriggered: {
            if (root.engine && root.configured && !root._authBlocked)
                root.engine.push();
        }
    }

    Timer {
        id: dueTimer

        onTriggered: pushSoon.restart()
    }

    Timer {
        id: retryTimer

        onTriggered: root._tick()
    }

    Timer {
        interval: Math.max(1, root.syncMinutes) * 60000
        repeat: true
        running: root.configured
        onTriggered: root._tick()
    }

    // Shortly after the shell starts, not with it: the network may still be
    // coming up at login. A failure just means a retry.
    Timer {
        id: firstSync

        interval: 4000
        onTriggered: root._tick()
    }

    // Back online with something waiting: send it now rather than at the
    // next retry.
    Connections {
        target: NetworkService

        function onNetworkStatusChanged() {
            if (!root._offline() && (root.status.waiting > 0 || root.status.lastErrorKind === "retry"))
                Qt.callLater(root._tick);
        }
    }

    // ------------------------------------------------------------ settings

    function _number(key, fallback, lo, hi) {
        const v = Math.round(Number(PluginService.loadPluginData(pluginId, key, fallback)));
        return isFinite(v) ? Math.max(lo, Math.min(hi, v)) : fallback;
    }

    function _loadSettings() {
        const text = (key, fallback) => String(PluginService.loadPluginData(pluginId, key, fallback) || "").trim();
        server = text("server", "");
        user = text("user", "");
        listName = text("listName", "main") || "main";
        syncMinutes = _number("syncMinutes", 5, 1, 1440);
        keepDoneHours = _number("keepDoneHours", 24, -1, 100000);
        passwordFile = text("passwordFile", "");
    }

    Connections {
        target: PluginService

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId !== root.pluginId)
                return;
            const before = [root.server, root.user, root.listName, root.password].join("\n");
            root._loadSettings();
            root._configure();
            if ([root.server, root.user, root.listName, root.password].join("\n") !== before) {
                root._authBlocked = false;
                firstSync.restart();
            }
        }
    }

    // ------------------------------------------------------------ secrets

    FileView {
        id: secretsFile

        path: root._secretsPath
        blockLoading: true
        printErrors: false
    }

    function _loadSecrets() {
        try {
            const raw = secretsFile.text();
            const saved = raw && raw.trim() ? JSON.parse(raw) : {};
            _storedPassword = typeof saved.password === "string" ? saved.password : "";
        } catch (e) {
            _storedPassword = "";
        }
    }

    // Written by sh under umask 077, so the file is never readable by
    // anyone else, not even between being created and a chmod. The password
    // reaches sh through its environment -- readable only by this user, like
    // the file itself -- never through its arguments, which `ps` shows
    // everyone.
    property bool _secretsDirty: false

    Process {
        id: secretsWriter

        command: ["sh", "-c", "umask 077 && mkdir -p \"$1\" && printf '%s' \"$QUICKNOTES_SECRETS\" > \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"", "sh", root._secretsDir, root._secretsPath]
        onExited: exitCode => {
            if (exitCode !== 0)
                ToastService.showError("Quick Notes", "Could not save the app password in " + root._secretsPath);
            if (root._secretsDirty) {
                root._secretsDirty = false;
                root._writeSecrets();
            }
        }
    }

    function _writeSecrets() {
        if (secretsWriter.running) {
            _secretsDirty = true;
            return;
        }
        secretsWriter.environment = {
            "QUICKNOTES_SECRETS": JSON.stringify({
                password: root._storedPassword
            })
        };
        secretsWriter.running = true;
    }

    // A password file of your own, read again whenever it changes.
    FileView {
        id: passwordFileView

        path: root.passwordFile ? Paths.expandTilde(root.passwordFile) : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const before = root._filePassword;
            root._filePassword = text().trim();
            root.passwordFileError = root._filePassword ? "" : "the file is empty";
            if (root._filePassword !== before)
                root._passwordChanged();
        }
        onLoadFailed: {
            root._filePassword = "";
            root.passwordFileError = "cannot read it";
            root._configure();
        }
    }

    // -------------------------------------------------------------- start

    Component.onCompleted: {
        _loadSettings();
        _loadSecrets();
        engine = Sync.createEngine({
            request: (req, done) => transport.request(req, done),
            now: () => Date.now(),
            changed: () => Qt.callLater(root._refresh),
            finished: (kind, err) => root._finished(kind, err)
        });
        engine.restore(PluginService.loadPluginState(pluginId, "cache", null));
        _configure();
        _refresh();
        firstSync.start();
    }

    Component.onDestruction: {
        _alive = false;
        transport.stop();
    }
}
