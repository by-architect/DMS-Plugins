pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "phone.js" as Phone

// One poller for the whole shell: the pill exists once per monitor and the
// popout comes and goes, so the phone is asked here and every surface reads
// the same answer.
//
// The phone is a host from SSH Hosts (sshManager) -- Termux's sshd -- picked
// in this plugin's settings. A check is one ssh: scripts/remote.sh goes in on
// stdin, `sh -s` runs it on the phone, and phone.js reads what comes back.
Singleton {
    id: root

    readonly property string pluginId: "phoneStatus"

    // ------------------------------------------------------------ settings
    property string hostKey: ""
    property int pollSeconds: 60
    property bool showPhotos: true
    property bool showNotificationCount: true

    readonly property string remoteScript: Paths.strip(Qt.resolvedUrl("./scripts/remote.sh"))
    readonly property string ringScript: Paths.strip(Qt.resolvedUrl("./scripts/ring.sh"))
    readonly property string photoDir: Paths.strip(Paths.cache) + "/phoneStatus/photos"

    // $1 is the script, fed to ssh as stdin; the rest is the ssh argv.
    readonly property string _wrap: 'command -v ssh >/dev/null 2>&1 || exit 91; f=$1; shift; exec "$@" < "$f"'

    readonly property int timeoutMs: 30000

    // ------------------------------------------------------------- the host
    readonly property var sshDaemon: PluginService.pluginDaemonInstances["sshManager"] ?? null
    property var _settingsHosts: []

    readonly property var allHosts: {
        const d = root.sshDaemon;
        const list = d ? d.hosts : root._settingsHosts;
        return Array.isArray(list) ? list.filter(h => h && h.id && h.host) : [];
    }

    // By id, as the settings store it -- or by name, for a hand-written one.
    readonly property var host: {
        const key = root.hostKey;
        if (!key)
            return null;
        return allHosts.find(h => h.id === key) || allHosts.find(h => (h.name || "").toLowerCase() === key.toLowerCase()) || null;
    }
    readonly property string phoneName: host ? (host.name || host.host) : ""

    // --------------------------------------------------------------- state
    property var result: null       // phone.js parseProbe(), from the last good check
    property string state: ""       // "online", "unreachable", "auth", "hostkey", "error", "" before the first
    property string detail: ""
    property real checkedMs: 0
    property real onlineMs: 0
    property bool checking: false
    property real dataPolledMs: 0
    property bool ringing: false
    property string ringNote: ""

    readonly property bool online: state === "online" && result !== null
    readonly property var notifications: result ? result.notifications.filter(n => !n.ongoing) : []
    readonly property var ongoing: result ? result.notifications.filter(n => n.ongoing) : []

    // Photo path on the phone -> local file, once fetched.
    property var photoFiles: ({})
    property var _photoQueue: []

    // How many pills read this, and whether a popout is open. A singleton
    // stays in the engine after its last pill is gone, so the poll is tied
    // to there being a reader.
    property int consumers: 0
    property int popouts: 0
    readonly property bool watching: consumers > 0 && host !== null

    onWatchingChanged: if (watching)
        refresh(false)
    onHostChanged: {
        result = null;
        state = "";
        detail = "";
        photoFiles = {};
        if (watching)
            refresh(false);
    }

    // The popout opening asks for everything fresh -- the data counter too,
    // which Android otherwise brings up to date only every half hour or so.
    onPopoutsChanged: if (popouts > 0)
        refresh(true)

    Timer {
        interval: Math.max(30, root.pollSeconds) * 1000
        repeat: true
        running: root.watching
        onTriggered: root.refresh(false)
    }

    // -------------------------------------------------------------- checks
    function sshArgv(remoteCmd) {
        const h = root.host;
        if (!h)
            return null;
        let base = null;
        const d = root.sshDaemon;
        if (d && typeof d.buildSshArgs === "function")
            base = d.buildSshArgs(h.id);
        if (!base) {
            base = ["ssh"];
            if (h.port && String(h.port) !== "22")
                base.push("-p", String(h.port));
            if (h.authMethod === "key" && h.identityFile)
                base.push("-i", Paths.expandTilde(h.identityFile));
            base.push(h.username ? h.username + "@" + h.host : h.host);
        }
        const opts = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "-o", "ControlMaster=no", "-o", "LogLevel=ERROR"];
        const dest = base[base.length - 1];
        return [base[0]].concat(opts, base.slice(1, base.length - 1), ["--", dest, remoteCmd]);
    }

    // full: also bring Android's data counter up to date (not more than once
    // every five minutes: it writes to the phone's storage) and fetch new
    // photos.
    // A refresh asked for while a check runs: done when it ends.
    property int _pending: 0 // 0 none, 1 regular, 2 full

    function refresh(full) {
        if (!root.host)
            return;
        if (root.checking) {
            root._pending = Math.max(root._pending, full ? 2 : 1);
            return;
        }
        if (root.host.authMethod === "password") {
            root.state = "error";
            root.detail = "needs key auth: set the phone up with a key in SSH Hosts";
            return;
        }
        const poll = full && Date.now() - root.dataPolledMs > 5 * 60 * 1000;
        if (poll)
            root.dataPolledMs = Date.now();
        probe.wantPhotos = full;
        probe.outText = "";
        probe.errText = "";
        probe.exitSeen = probe.outSeen = probe.errSeen = probe.timedOut = false;
        probe.startedMs = Date.now();
        probe.environment = {
            "LC_ALL": "C"
        };
        probe.command = ["sh", "-c", root._wrap, "phonestatus-probe", root.remoteScript].concat(root.sshArgv(poll ? "sh -s poll" : "sh -s"));
        root.checking = true;
        probe.running = true;
    }

    Process {
        id: probe

        property bool wantPhotos: false
        property real startedMs: 0
        property int code: -1
        property bool exitSeen: false
        property bool outSeen: false
        property bool errSeen: false
        property bool timedOut: false
        property string outText: ""
        property string errText: ""

        running: false

        stdout: StdioCollector {
            waitForEnd: false
            onStreamFinished: {
                probe.outText = text || "";
                probe.outSeen = true;
                root._maybeFinish();
            }
        }

        stderr: StdioCollector {
            waitForEnd: false
            onStreamFinished: {
                probe.errText = text || "";
                probe.errSeen = true;
                root._maybeFinish();
            }
        }

        onExited: exitCode => {
            probe.code = exitCode;
            probe.exitSeen = true;
            root._maybeFinish();
        }
    }

    // The exit code and both streams arrive in no fixed order.
    function _maybeFinish() {
        if (root.checking && probe.exitSeen && probe.outSeen && probe.errSeen)
            _finish();
    }

    function _finish() {
        if (!root.checking)
            return;
        root.checking = false;
        if (root._pending > 0) {
            const full = root._pending === 2;
            root._pending = 0;
            Qt.callLater(() => root.refresh(full));
        }
        const now = Date.now();
        const parsed = Phone.parseProbe(probe.outText, now);
        root.checkedMs = now;
        if (parsed.begun) {
            root.result = parsed;
            root.state = "online";
            root.detail = parsed.complete ? "" : "the answer was cut short";
            root.onlineMs = now;
            if (probe.wantPhotos)
                root._fetchPhotos();
        } else {
            const v = Phone.classify(probe.code, probe.errText, probe.timedOut);
            root.state = v.state;
            root.detail = v.detail;
        }
    }

    // One watchdog: past the deadline the check is stopped and the phone
    // counts as unreachable; an exited check whose streams stay open is
    // finished with what it has.
    Timer {
        interval: 1000
        repeat: true
        running: root.checking
        onTriggered: {
            const age = Date.now() - probe.startedMs;
            if (age > root.timeoutMs && !probe.timedOut) {
                probe.timedOut = true;
                probe.running = false;
            } else if (age > root.timeoutMs + 4000) {
                probe.outText = probe.outText || probe.stdout.text || "";
                probe.errText = probe.errText || probe.stderr.text || "";
                root._finish();
            } else if (probe.exitSeen && age > 2000 && (!probe.outSeen || !probe.errSeen)) {
                probe.outText = probe.outText || probe.stdout.text || "";
                probe.errText = probe.errText || probe.stderr.text || "";
                root._finish();
            }
        }
    }

    // ------------------------------------------------------------- photos
    //
    // The newest few photos and screenshots, copied into the shell's cache
    // the first time they are seen (only while the popout is open), and
    // shown from there. Photos that drop out of the newest are deleted again.
    function _fetchPhotos() {
        if (!root.showPhotos || !root.result)
            return;
        const wanted = root.result.photos.filter(p => /^\/[\w .,+\-\/()]+$/.test(p) && p.indexOf("'") < 0);
        const keep = {};
        const queue = [];
        for (const p of wanted) {
            const local = root.photoDir + "/" + p.split("/").pop();
            keep[p] = local;
            if (root.photoFiles[p] !== local)
                queue.push(p);
        }
        // Forget (and delete) what is no longer among the newest.
        const names = Object.values(keep).map(f => f.split("/").pop());
        Quickshell.execDetached(["sh", "-c", 'd=$1; shift; mkdir -p "$d"; cd "$d" || exit; for f in *; do [ -f "$f" ] || continue; keep=0; for k in "$@"; do [ "$f" = "$k" ] && keep=1; done; [ $keep = 1 ] || rm -f -- "$f"; done', "phonestatus-prune", root.photoDir].concat(names));
        const next = {};
        for (const p in root.photoFiles)
            if (keep[p])
                next[p] = root.photoFiles[p];
        root.photoFiles = next;
        root._photoQueue = queue;
        _nextPhoto();
    }

    function _nextPhoto() {
        if (photoJob.running || root._photoQueue.length === 0)
            return;
        const p = root._photoQueue[0];
        root._photoQueue = root._photoQueue.slice(1);
        const local = root.photoDir + "/" + p.split("/").pop();
        photoJob.remote = p;
        photoJob.local = local;
        // Root reads it: the phone's shared storage is not Termux's to read.
        const argv = root.sshArgv("su -c \"cat '" + p + "'\" 2>/dev/null || cat '" + p + "'");
        photoJob.command = ["sh", "-c", 'out=$1; shift; mkdir -p "$(dirname "$out")"; if [ -s "$out" ]; then exit 0; fi; "$@" > "$out.part" && [ -s "$out.part" ] && mv "$out.part" "$out" || { rm -f "$out.part"; exit 1; }', "phonestatus-photo", local].concat(argv);
        photoJob.running = true;
    }

    Process {
        id: photoJob

        property string remote: ""
        property string local: ""

        running: false
        onExited: exitCode => {
            if (exitCode === 0) {
                const next = Object.assign({}, root.photoFiles);
                next[photoJob.remote] = photoJob.local;
                root.photoFiles = next;
            }
            Qt.callLater(root._nextPhoto);
        }
    }

    // ------------------------------------------------------------ actions
    function ring() {
        if (!root.host || ringJob.running)
            return;
        root.ringing = true;
        root.ringNote = "";
        ringJob.command = ["sh", "-c", root._wrap, "phonestatus-ring", root.ringScript].concat(root.sshArgv("sh -s"));
        ringJob.running = true;
    }

    Process {
        id: ringJob

        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const m = /ps:ring (.*)/.exec(text || "");
                root.ringNote = m && m[1] !== "done" ? m[1] : "";
                if (root.ringNote !== "")
                    ToastService.showWarning("Couldn't ring " + root.phoneName, root.ringNote);
            }
        }
        onExited: root.ringing = false
    }

    function lock() {
        _quick("su -c 'input keyevent KEYCODE_SLEEP'", "Locked " + root.phoneName);
    }

    function _quick(remoteCmd, okText) {
        const argv = root.sshArgv(remoteCmd);
        if (!argv)
            return;
        quickJob.okText = okText;
        quickJob.command = argv;
        quickJob.running = true;
    }

    Process {
        id: quickJob

        property string okText: ""

        running: false
        onExited: exitCode => {
            if (exitCode === 0)
                ToastService.showInfo(quickJob.okText, "");
            else
                ToastService.showWarning("That didn't work", root.phoneName + " did not answer");
        }
    }

    // SSH Hosts' own connect action, so the terminal is the one set up there.
    function openSession() {
        const h = root.host;
        if (!h)
            return;
        const d = root.sshDaemon;
        if (d && typeof d.connect === "function") {
            d.connect(h.id);
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
        hostKey = String(PluginService.loadPluginData(pluginId, "host", "") || "");
        pollSeconds = PluginService.loadPluginData(pluginId, "pollSeconds", 60);
        showPhotos = PluginService.loadPluginData(pluginId, "showPhotos", true);
        showNotificationCount = PluginService.loadPluginData(pluginId, "showNotificationCount", true);
    }

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

    // dms ipc call phoneStatus status | refresh | ring
    IpcHandler {
        target: "phoneStatus"

        function status(): string {
            if (!root.host)
                return "no phone picked in the settings";
            const r = root.result;
            const lines = [root.phoneName + "\t" + (root.state || "not checked") + (root.detail ? "\t" + root.detail : "") + (root.checkedMs ? "\tchecked " + Phone.agoText(root.checkedMs, Date.now()) : "")];
            if (r) {
                if (r.battery)
                    lines.push("battery\t" + r.battery.level + "%\t" + r.battery.state + (isFinite(r.battery.tempC) ? "\t" + r.battery.tempC.toFixed(1) + " °C" : ""));
                if (r.cell)
                    lines.push("signal\t" + [r.cell.operator, r.cell.rat, Phone.signalWords(r.cell.level), isFinite(r.cell.dbm) ? r.cell.dbm + " dBm" : ""].filter(x => x).join("\t"));
                if (r.data)
                    lines.push("mobile data\t" + Phone.bytesText(r.data.used) + " since " + Phone.dayText(r.data.start) + "\ttoday " + Phone.bytesText(r.data.today));
                if (r.hotspot)
                    lines.push("hotspot\t" + (r.hotspot.on ? "on, " + r.hotspot.clients + " connected" : "off"));
                lines.push("notifications\t" + root.notifications.length + " (+" + root.ongoing.length + " ongoing)");
                if (r.media)
                    lines.push("media\t" + (r.media.playing ? "playing" : "paused") + "\t" + r.media.title + (r.media.artist ? " — " + r.media.artist : ""));
            }
            return lines.join("\n");
        }

        function refresh(): string {
            root.refresh(true);
            return root.host ? "checking " + root.phoneName : "no phone picked in the settings";
        }

        function ring(): string {
            root.ring();
            return root.host ? "ringing " + root.phoneName : "no phone picked in the settings";
        }
    }
}
