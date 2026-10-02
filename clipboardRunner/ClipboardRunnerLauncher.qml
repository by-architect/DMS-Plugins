import QtQuick
import Quickshell
import qs.Common
import qs.Services
import "clipboard.js" as Clipboard
import "presets.js" as Presets

// Launcher provider for clipboard actions. Actions are defined in the plugin's
// settings panel ("actions" setting, each entry
// {enabled, name, icon, group, extensions, conditions[], command}); this
// component reads the clipboard, works out what kind of thing is on it, and
// lists only the actions whose group and filters accept it.
//
// Nothing runs on its own. An action runs when you pick it here.
Item {
    id: root

    readonly property string pluginId: "clipboardRunner"

    property var pluginService: null
    property string trigger: "clip "

    signal itemsChanged

    property var actions: []

    // Passed to every command: where downloads land, and the terminal for the
    // two or three actions that genuinely need one.
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/dms-clipboard-runner"

    property string downloadDir: ""
    property string terminal: "ghostty -e"

    readonly property var ctx: ({
            "downloads": downloadDir,
            "terminal": terminal,
            "cache": cacheDir
        })

    // Sharing goes through the chat runner: it already lists every conversation
    // from every provider, and a second conversation picker living here would
    // be the same list with its own bugs. The chat manager is a plugin of its
    // own, so the row is offered only when that plugin is loaded and its
    // manager is running -- otherwise it is a row that can only fail.
    readonly property var chatDaemon: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        return instances["chatManager"] ?? null;
    }
    readonly property bool canShare: root.chatDaemon?.chat?.available ?? false

    // The word that puts the chat runner into its share list. Written out here
    // as well because the handoff is a launcher query, which is text.
    readonly property string shareKeyword: "share"

    // KDE Connect devices that are paired and reachable right now, each as
    // {id, name}. Kept cached for the same reason as the clipboard below:
    // getItems() cannot wait on kdeconnect-cli. Without kdeconnect-cli, or
    // with no device in reach, this is empty and no device rows appear.
    property var kdeDevices: []
    property bool listingDevices: false
    property double devicesListedAt: 0

    // getItems() has to answer synchronously, so the clipboard is kept cached
    // ahead of time rather than fetched on demand: read once when the instance
    // is created, and again whenever the clipboard changes. That is one small
    // socket round trip per copy, and only after the runner has been used at
    // least once, because the instance itself is created lazily by
    // ensureLauncherInstance(). A read that lands while the launcher is open
    // still shows up by itself -- see _refreshLauncher.
    property var detail: null
    property bool reading: false
    property string readError: ""

    Component.onCompleted: {
        _seed();
        _loadSettings();
        _readClipboard();
        _listDevices();
    }
    onPluginServiceChanged: {
        _seed();
        _loadSettings();
    }

    // The shipped actions are written into the list once, the first time the
    // plugin runs. After that they are ordinary entries and this does nothing.
    function _seed() {
        const message = Presets.seedIfNeeded(pluginService, pluginId);
        if (message)
            log(message);
    }

    // A burst of copies (a script, a multi-select) should cost one read, not one
    // per change.
    Timer {
        id: readDebounce
        interval: 150
        repeat: false
        onTriggered: {
            root._readClipboard();
            root._listDevices();
        }
    }

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId !== root.pluginId)
                return;
            root._loadSettings();
            root._refreshLauncher();
        }
    }

    Connections {
        target: DMSService
        function onClipboardStateUpdate(data) {
            readDebounce.restart();
        }
    }

    function _loadSettings() {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData(pluginId, "trigger", "clip ");
        downloadDir = pluginService.loadPluginData(pluginId, "downloadDir", "") || (Quickshell.env("HOME") + "/Downloads");
        terminal = pluginService.loadPluginData(pluginId, "terminal", "ghostty -e");
        const loaded = pluginService.loadPluginData(pluginId, "actions", []);
        actions = Array.isArray(loaded) ? loaded : [];
    }

    // requestLauncherUpdate is what redraws an open launcher: the launcher's
    // controller listens for it and runs its current search again, so a
    // clipboard read, a device list or a settings edit that lands while the
    // list is showing replaces it without anything being typed. itemsChanged
    // is not connected to anything in the shell; it is only emitted for the
    // plugin contract's sake.
    function _refreshLauncher() {
        itemsChanged();
        if (pluginService && typeof pluginService.requestLauncherUpdate === "function")
            pluginService.requestLauncherUpdate(pluginId);
    }

    // The newest entry's type is asked first, and only that entry -- a search
    // capped at one, where the full state would carry the whole history. A
    // video, a sound or another file copied as data is written out to a file
    // (see Clipboard.dataExt); anything else is read as text.
    function _readClipboard() {
        if (reading)
            return;
        if (!DMSService.isConnected) {
            detail = null;
            readError = "DMS is not connected";
            return;
        }

        reading = true;
        DMSService.sendRequest("clipboard.search", {
            "limit": 1
        }, function (response) {
            const entries = (!response.error && response.result && response.result.entries) || [];
            const newest = entries.length > 0 ? entries[0] : null;
            const ext = newest && !newest.isImage ? Clipboard.dataExt(newest.mimeType) : "";
            if (ext !== "")
                root._materialise(newest, ext);
            else
                root._readText();
        });
    }

    // clipboard.paste hands back the full current clipboard as text, unlike the
    // history previews which stop at 100 characters. It fails for a clipboard
    // holding an image and nothing else, which is where _readImage takes over.
    function _readText() {
        DMSService.sendRequest("clipboard.paste", null, function (response) {
            if (response.error) {
                root._readImage();
                return;
            }
            const text = (response.result && response.result.text) || "";
            if (text.trim().length === 0) {
                root._readImage();
                return;
            }
            root._settle(text);
        });
    }

    // An image copied out of a browser or a screenshot tool is real content with
    // no file behind it, so there is nothing for a file action to open. Writing
    // it into the cache gives it a path, and from there it is an image file like
    // any other -- every conversion in the file group applies to it.
    function _readImage() {
        DMSService.sendRequest("clipboard.getState", null, function (response) {
            const current = response.result && response.result.current;
            if (response.error || !current || !current.isImage) {
                root._fail(response.error || "Clipboard has nothing this can act on");
                return;
            }
            root._materialise(current, root._extForMime(current.mimeType));
        });
    }

    // Named after the entry, so the same copy is written out once however
    // often the list is opened. `cl get` prints the entry's bytes as base64,
    // whatever their type. pipefail, because otherwise a failed `cl get` is
    // reported as base64's success on no input: an empty file, then actions
    // offered on nothing. A half-written file is removed, never reused.
    function _materialise(entry, ext) {
        const file = root.cacheDir + "/clipboard-" + entry.id + "." + ext;
        Proc.runCommand("clipboardRunner.materialise", ["zsh", "-c", 'setopt pipefail
mkdir -p "${1:h}" || exit 1
if [ ! -s "$1" ]; then
    "${DMS_EXECUTABLE:-dms}" cl get "$2" | base64 -d > "$1.part" && [ -s "$1.part" ] && mv -f "$1.part" "$1" || { rm -f "$1.part"; exit 1; }
fi', "materialise", file, String(entry.id)], function (output, exitCode) {
            if (exitCode !== 0) {
                root._fail(entry.isImage ? "Could not write the clipboard image out" : "Could not write the copied " + (entry.mimeType || "data") + " out");
                return;
            }
            root._settle(file);
        }, 0, 60000);
    }

    function _extForMime(mime) {
        switch ((mime || "").toLowerCase()) {
        case "image/jpeg":
            return "jpg";
        case "image/gif":
            return "gif";
        case "image/webp":
            return "webp";
        case "image/bmp":
            return "bmp";
        case "image/tiff":
            return "tiff";
        default:
            return "png";
        }
    }

    // Whether a path is a folder is not something the text can say, so it is
    // asked of the filesystem before the list is built. Anything that is not a
    // path skips the round trip.
    function _settle(text) {
        const probe = Clipboard.describe(text);
        if (probe.type !== "path") {
            root.reading = false;
            root.detail = probe;
            root.readError = "";
            root._refreshLauncher();
            return;
        }

        Proc.runCommand("clipboardRunner.stat", ["zsh", "-c", 'if [ -d "$1" ]; then print dir; elif [ -e "$1" ]; then print file; else print missing; fi', "stat", probe.path], function (output, exitCode) {
            root.reading = false;
            root.detail = Clipboard.describe(text, (output || "").trim() === "dir");
            root.readError = "";
            root._refreshLauncher();
        });
    }

    // A phone drops off the network and comes back all day, so the list is
    // asked for again on every copy and, at most every few seconds, while the
    // runner is being typed into.
    function _listDevices() {
        if (listingDevices)
            return;
        listingDevices = true;
        devicesListedAt = Date.now();
        Proc.runCommand("clipboardRunner.kdeDevices", ["kdeconnect-cli", "--list-available", "--id-name-only"], function (output, exitCode) {
            root.listingDevices = false;
            const found = [];
            if (exitCode === 0) {
                for (const line of (output || "").split("\n")) {
                    const match = line.trim().match(/^(\S+)\s+(.+)$/);
                    if (match && !/devices? found$/.test(line.trim()))
                        found.push({
                            "id": match[1],
                            "name": match[2]
                        });
                }
            }
            if (JSON.stringify(found) === JSON.stringify(root.kdeDevices))
                return;
            root.kdeDevices = found;
            root._refreshLauncher();
        });
    }

    function _fail(message) {
        reading = false;
        detail = null;
        readError = message;
        _refreshLauncher();
    }

    function getItems(query) {
        // Sharing needs no actions of its own, so an empty action list is a
        // hint rather than the whole answer once the chat runner is there.
        if (Date.now() - devicesListedAt > 5000)
            _listDevices();

        if (actions.length === 0 && !canShare && kdeDevices.length === 0)
            return [_statusItem("settings", "No clipboard actions yet", "Add one in Settings → Plugins → Clipboard Runner")];

        // Only reachable before the first read has landed. The read redraws
        // the launcher itself when it lands, so this row is replaced without
        // typing anything -- unless DMS is not connected, where the read
        // fails on the spot without ever sending a request; that falls
        // through to the error row below instead of claiming a read is
        // still on its way.
        if (!detail && !readError) {
            _readClipboard();
            if (!detail && !readError)
                return [_statusItem("hourglass_empty", "Reading the clipboard…", "")];
        }

        if (!detail)
            return [_statusItem("content_paste_off", readError || "Nothing usable on the clipboard", "")];

        const matched = Clipboard.matchAll(actions, detail);
        const kind = Clipboard.groupLabel(detail.type).toLowerCase();

        const q = (query || "").trim().toLowerCase();
        const filtered = q.length === 0 ? matched : matched.filter(a => {
            return (a.name || "").toLowerCase().includes(q) || (a.command || "").toLowerCase().includes(q);
        });

        const rows = filtered.map((a, i) => ({
            id: "clip:" + detail.type + ":" + i + ":" + (a.name || ""),
            name: a.name || a.command || "Unnamed action",
            icon: a.icon || ("material:" + Clipboard.groupIcon(detail.type)),
            comment: Clipboard.preview(a, detail, root.ctx),
            action: "execute",
            categories: ["Clipboard"],
            actionEntry: a
        }));

        // Sharing is offered whatever is on the clipboard and whatever the
        // actions say, because it is not filtered by content type: a chat
        // takes a link, a colour or a file just as happily. First, so it is
        // one keystroke away rather than somewhere under the actions.
        // One row per KDE Connect device, straight after the chat row for the
        // same reason.
        rows.unshift(..._deviceItems(q));

        const share = _shareItem(q);
        if (share)
            rows.unshift(share);

        if (actions.length === 0)
            rows.push(_statusItem("settings", "No clipboard actions yet", "Add one in Settings → Plugins → Clipboard Runner"));

        if (rows.length === 0) {
            return matched.length === 0 ? [_statusItem("filter_alt_off", "No " + kind + " action matches this", _clip())] : [_statusItem("search_off", "No action matches \"" + query + "\"", _clip())];
        }

        return rows;
    }

    // The row that hands the clipboard to the chat runner. Null when the chat
    // manager is not there to hand it to, or when the query is clearly after
    // something else.
    function _shareItem(query) {
        if (!canShare || !detail)
            return null;
        if (query.length > 0 && !"share to a chat send message conversation".includes(query))
            return null;

        const payload = _sharePayload();
        return {
            id: "clip:share",
            name: "Share to a chat…",
            icon: "material:forum",
            comment: (payload && payload.kind === "file" ? "Send this file to a conversation" : "Send this text to a conversation") + "  ·  " + _clip(),
            action: "execute",
            categories: ["Clipboard"],
            keywords: ["share", "chat", "send", "message"]
        };
    }

    function _deviceItems(query) {
        if (!detail)
            return [];

        const payload = _devicePayload();
        return kdeDevices.filter(d => {
            return query.length === 0 || ("send to " + d.name + " kde connect phone device share").toLowerCase().includes(query);
        }).map(d => ({
                    id: "clip:kde:" + d.id,
                    name: "Send to " + d.name,
                    icon: "material:smartphone",
                    comment: payload.what + " over KDE Connect  ·  " + _clip(),
                    action: "execute",
                    categories: ["Clipboard"],
                    keywords: ["share", "send", "kde", "phone", d.name],
                    kdeDevice: d
                }));
    }

    // What a device gets. A file goes as the file and a link as a link, which
    // the phone opens; a folder cannot be sent, so like anything else it goes
    // as text.
    function _devicePayload() {
        if (detail.type === "path" && !detail.isDir)
            return {
                "what": "Send this file",
                "args": ["--share", detail.path]
            };
        if (detail.type === "url")
            return {
                "what": "Open this link",
                "args": ["--share", detail.text]
            };
        return {
            "what": "Send this text",
            "args": ["--share-text", detail.text]
        };
    }

    function _sendToDevice(device) {
        const payload = _devicePayload();
        Proc.runCommand("clipboardRunner.kdeShare." + device.id, ["kdeconnect-cli", "--device", device.id].concat(payload.args), function (output, exitCode) {
            if (exitCode === 0)
                root._toast("Sent to " + device.name, root._clip());
            else if (typeof ToastService !== "undefined")
                ToastService.showError("Could not send to " + device.name, (output || "").trim() || ("kdeconnect-cli exited with " + exitCode));
        });
    }

    // What sharing would actually send. A file is sent as an attachment; a
    // folder cannot be attached, so it travels as its path, like any other
    // text.
    function _sharePayload() {
        if (!detail)
            return null;

        if (detail.type === "path" && !detail.isDir)
            return {
                "kind": "file",
                "path": detail.path,
                "label": detail.basename || detail.path,
                "ts": Date.now()
            };

        return {
            "kind": "text",
            "text": detail.text,
            "label": _clip(),
            "ts": Date.now()
        };
    }

    // The handoff itself.
    //
    // The clipboard is left in the chat runner's own state rather than passed
    // as a query, because the query is what the user sees and types over --
    // and a file path or a paragraph of text does not belong in a search box.
    function _share() {
        const payload = _sharePayload();
        if (!payload || !pluginService) {
            _toast("Nothing to share", readError);
            return;
        }

        pluginService.savePluginState("chatRunner", "pendingShare", payload);
        shareHandoff.restart();
    }

    // The launcher closes itself the moment an item runs, so reaching another
    // runner means opening it again once that has happened rather than
    // rewriting the query in place.
    Timer {
        id: shareHandoff
        interval: 80
        repeat: false
        onTriggered: root._openChatRunner()
    }

    function _openChatRunner() {
        const trigger = pluginService && typeof pluginService.getPluginTrigger === "function" ? pluginService.getPluginTrigger("chatRunner") : null;
        // An empty trigger is a chat runner set to answer without one, which
        // the keyword alone reaches; null is a runner the shell does not know
        // about, where its shipped trigger is the best guess left.
        const prefix = (trigger === null || trigger === undefined) ? "c " : trigger;
        const query = prefix + root.shareKeyword + " ";

        if (typeof PopoutService !== "undefined" && typeof PopoutService.openDankLauncherV2WithQuery === "function") {
            PopoutService.openDankLauncherV2WithQuery(query);
            return;
        }
        // Proc.dmsBin for the same reason the presets go through
        // $DMS_EXECUTABLE: the shell's children don't always have dms on PATH.
        Quickshell.execDetached([Proc.dmsBin, "ipc", "call", "spotlight", "openQuery", query]);
    }

    function executeItem(item) {
        if (!item || !detail)
            return;

        if (item.id === "clip:share") {
            _share();
            return;
        }

        if (item.kdeDevice) {
            _sendToDevice(item.kdeDevice);
            return;
        }

        if (!item.actionEntry)
            return;

        const entry = item.actionEntry;
        const command = Clipboard.resolveCommand(entry, detail, root.ctx);
        if (!command) {
            _toast("This action has no command", entry.name || "");
            return;
        }

        Quickshell.execDetached({
            "command": command
        });
        _toast("Running " + (entry.name || entry.command), Clipboard.preview(entry, detail, root.ctx));
    }

    function getContextMenuActions(item) {
        if (!item || !item.actionEntry || !detail)
            return [];

        const entry = item.actionEntry;
        return [
            {
                icon: "content_copy",
                text: "Copy the command",
                action: () => {
                    const line = Clipboard.preview(entry, root.detail, root.ctx);
                    Quickshell.execDetached([Proc.dmsBin, "cl", "copy", line]);
                    root._toast("Copied", line);
                }
            }
        ];
    }

    // A one-line reminder of what is actually on the clipboard, for the rows
    // that are telling you nothing matched it.
    function _clip() {
        if (!detail)
            return "";
        const flat = detail.text.replace(/\s+/g, " ");
        return flat.length > 80 ? flat.substring(0, 77) + "…" : flat;
    }

    function _statusItem(icon, name, comment) {
        return {
            id: "clip:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: "noop",
            categories: ["Clipboard"]
        };
    }

    function log(message) {
        if (typeof Log !== "undefined")
            Log.scoped("clipboardRunner").info(message);
    }

    function _toast(title, body) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, body);
    }
}
