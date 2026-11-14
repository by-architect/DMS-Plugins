import QtQuick
import qs.Common
import qs.Services
import "contacts.js" as Contacts

// "call <name or number>": the phone's contacts and newest calls, and the
// one picked is rung from the phone itself.
//
// The phone is a host from SSH Hosts (sshManager), picked in the settings,
// or Phone Status's phone when none is. scripts/phone.sh goes in on ssh's
// stdin and runs as root (su): it lists the contacts and calls, or starts a
// call with Android's own CALL intent. When ssh cannot reach the phone, adb
// is tried -- only the device whose serial is the phone's own, learned over
// ssh, or the one named in the settings.
//
// The contacts are kept in the plugin's state, so the list is there at once
// and survives a restart; opening the launcher reads them again in the
// background when they are older than the settings say.
Item {
    id: root

    property var pluginService: null

    readonly property string pluginId: "callRunner"
    readonly property string phoneScript: Paths.strip(Qt.resolvedUrl("./scripts/phone.sh"))

    // Contacts.parse() of the last good read, with atMs; null before one
    property var book: null
    property bool loading: false
    property string loadError: ""
    property bool calling: false

    // $1 the script, $2 mode, $3 number, $4 the phone's serial for adb; the
    // rest is the ssh argv, or nothing without an ssh host. ssh's own
    // failure to connect is 255; anything else is the phone's answer.
    readonly property string _wrap: 'f=$1 mode=$2 num=$3 serial=$4; shift 4; out="" rc=255; ' + 'if [ $# -gt 0 ] && command -v "$1" >/dev/null 2>&1; then out=$("$@" < "$f" 2>&1); rc=$?; ' + '[ $rc -ne 255 ] && { printf "%s\\n" "$out"; exit $rc; }; fi; ' + 'adb=$(command -v adb) || for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" "$HOME/Opt/Android/Sdk"; do ' + '[ -n "$d" ] && [ -x "$d/platform-tools/adb" ] && { adb=$d/platform-tools/adb; break; }; done; ' + 'if [ -n "$serial" ] && [ -n "$adb" ] && "$adb" devices 2>/dev/null | grep -q "^$serial[[:space:]]*device"; then ' + 'echo "cr:via adb"; "$adb" -s "$serial" shell "sh -s $mode \'$num\'" < "$f" 2>&1; exit $?; fi; ' + 'printf "%s\\n" "$out"; ' + 'if [ $# -gt 0 ]; then echo "cr:error ssh cannot reach the phone${serial:+, and adb has no phone $serial}"; else echo "cr:error adb has no phone ${serial:-(no serial known yet)}"; fi; exit 255'

    function _setting(key, fallback) {
        return root.pluginService ? root.pluginService.loadPluginData(root.pluginId, key, fallback) : fallback;
    }

    // ------------------------------------------------------------ the phone
    readonly property var sshDaemon: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        return instances["sshManager"] ?? null;
    }

    function _hosts() {
        const list = root.sshDaemon ? root.sshDaemon.hosts : (root.pluginService ? root.pluginService.loadPluginData("sshManager", "hosts", []) : []);
        return Array.isArray(list) ? list.filter(h => h && h.id && h.host) : [];
    }

    // This plugin's pick, else Phone Status's: one phone, set up once.
    function _host() {
        let key = _setting("host", "");
        if (!key && root.pluginService)
            key = root.pluginService.loadPluginData("phoneStatus", "host", "");
        if (!key)
            return null;
        const hosts = _hosts();
        return hosts.find(h => h.id === key) || hosts.find(h => (h.name || "").toLowerCase() === String(key).toLowerCase()) || null;
    }

    function _phoneName() {
        const h = _host();
        return h ? (h.name || h.host) : "the phone";
    }

    function _serial() {
        return String(_setting("adbSerial", "") || (root.book ? root.book.serial : "") || "").trim();
    }

    function _sshArgv(remoteCmd) {
        const h = _host();
        if (!h || h.authMethod === "password")
            return [];
        let base = null;
        if (root.sshDaemon && typeof root.sshDaemon.buildSshArgs === "function")
            base = root.sshDaemon.buildSshArgs(h.id);
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

    // mode: contacts, call or hangup; number only for call, already dialable.
    function _run(id, mode, number, timeoutMs, done) {
        const remote = "sh -s " + mode + (number ? " '" + number + "'" : "");
        const argv = ["sh", "-c", root._wrap, "callrunner", root.phoneScript, mode, number || "", _serial()].concat(_sshArgv(remote));
        Proc.runCommand(id, argv, (out, code) => done(Contacts.parse(out || ""), code), 0, timeoutMs);
    }

    // -------------------------------------------------------------- the book
    Component.onCompleted: Qt.callLater(_restore)
    onPluginServiceChanged: _restore()

    function _restore() {
        if (root.book || !root.pluginService || typeof root.pluginService.loadPluginState !== "function")
            return;
        const saved = root.pluginService.loadPluginState(root.pluginId, "book", null);
        if (saved && Array.isArray(saved.contacts))
            root.book = saved;
    }

    function refresh(force) {
        if (root.loading)
            return;
        const ageMs = root.book ? Date.now() - (root.book.atMs || 0) : Infinity;
        const everyMs = Math.max(1, Number(_setting("refreshMinutes", 15))) * 60000;
        if (!force && ageMs < everyMs)
            return;
        if (!_host() && !_serial()) {
            root.loadError = "no phone picked: choose it in Settings → Plugins → Call Runner";
            return;
        }
        root.loading = true;
        _run("callRunner.contacts", "contacts", "", 45000, (got, code) => {
            root.loading = false;
            if (got.ok === "contacts") {
                got.atMs = Date.now();
                // A device that answers but lets nobody read the contacts
                // keeps the last good list.
                if (got.contacts.length > 0 || !root.book || got.error === "")
                    root.book = {
                        "atMs": got.atMs,
                        "serial": got.serial || (root.book ? root.book.serial : ""),
                        "contacts": got.contacts,
                        "calls": got.calls,
                        "via": got.via
                    };
                root.loadError = got.error;
                if (root.pluginService && typeof root.pluginService.savePluginState === "function")
                    root.pluginService.savePluginState(root.pluginId, "book", root.book);
            } else {
                root.loadError = got.error || (code === 124 ? "the phone did not answer in time" : "could not read the contacts (exit " + code + ")");
            }
            if (root.pluginService)
                root.pluginService.requestLauncherUpdate(root.pluginId);
        });
    }

    // ------------------------------------------------------------- launcher
    function _status(icon, name, comment, action, rank) {
        return {
            "id": "callRunner:status:" + name,
            "name": name,
            "icon": "material:" + icon,
            "comment": comment,
            "categories": ["Calls"],
            "_preScored": rank === undefined ? 10000 : rank,
            "action": action || ""
        };
    }

    // The keyword for ending the call the phone is in; "end" would hide
    // everybody named Ender.
    function _isHangup(q) {
        const l = q.toLowerCase();
        return l.length >= 4 && ("hang up".indexOf(l) === 0 || "hangup".indexOf(l) === 0);
    }

    function getItems(query) {
        const q = (query || "").trim();
        refresh(false);
        const items = [];
        if (_isHangup(q))
            items.push(_status("call_end", "Hang up", "End the call " + _phoneName() + " is in", "hangup"));
        if (q.toLowerCase() === "refresh")
            items.push(_status("sync", "Read the contacts again", "From " + _phoneName() + (root.book ? ", last read " + Contacts.agoText(root.book.atMs, Date.now()) : ""), "refresh"));

        const rows = Contacts.rows(root.book, q, {
            "max": Number(_setting("maxResults", 40)),
            "recent": Number(_setting("recentCount", 8)),
            "nowMs": Date.now()
        });
        for (let i = 0; i < rows.length; i++) {
            const r = rows[i];
            items.push({
                "id": "callRunner:" + Contacts.dialable(r.number) + ":" + i,
                "name": r.name,
                "icon": "material:" + r.icon,
                "comment": r.comment,
                "categories": ["Calls"],
                "keywords": [r.number],
                // Kept in this order: the launcher's own scorer knows nothing
                // of numbers or of who was called last.
                "_preScored": 9000 - i,
                "action": "call",
                "number": Contacts.dialable(r.number),
                "who": r.who
            });
        }

        if (items.length === 0) {
            if (!root.book && root.loading)
                return [_status("hourglass_empty", "Reading the contacts on " + _phoneName() + "…", "")];
            if (!root.book && root.loadError)
                return [_status("phone_disabled", "No contacts", root.loadError, "refresh")];
            return [_status("search_off", "Nobody matches \"" + q + "\"", "Type a name or a number; \"refresh\" reads the contacts again")];
        }
        if (root.loadError && root.book)
            items.push(_status("sync_problem", "Contacts from " + Contacts.agoText(root.book.atMs, Date.now()), root.loadError + " — Enter tries again", "refresh", 1));
        return items;
    }

    function executeItem(item) {
        if (!item)
            return;
        if (item.action === "refresh") {
            root.loadError = "";
            refresh(true);
            ToastService.showInfo("Reading the contacts on " + _phoneName());
            return;
        }
        if (item.action === "hangup") {
            _run("callRunner.hangup", "hangup", "", 20000, (got, code) => {
                if (got.ok === "hangup")
                    ToastService.showInfo("Hung up", "on " + _phoneName());
                else
                    ToastService.showError("Not hung up", got.error || ("exit " + code));
            });
            return;
        }
        if (item.action !== "call" || !item.number)
            return;
        if (root.calling) {
            ToastService.showWarning("Already calling", "wait for the phone to answer the last one");
            return;
        }
        const who = item.who || item.number;
        root.calling = true;
        ToastService.showInfo("Calling " + who, "on " + _phoneName());
        _run("callRunner.call", "call", item.number, 25000, (got, code) => {
            root.calling = false;
            if (got.ok !== "call") {
                ToastService.showError("Could not call " + who, got.error || (code === 124 ? "the phone did not answer in time" : "exit " + code));
                return;
            }
            // The intent went in, but the phone is not in a call: its dialer
            // asks something first -- which SIM, most often.
            if (got.state === 0)
                ToastService.showWarning("Look at the phone", "it did not start calling " + who + " -- it may be asking which SIM to use");
        });
    }
}
