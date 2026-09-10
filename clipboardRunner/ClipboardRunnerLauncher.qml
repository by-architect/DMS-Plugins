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
    property string downloadDir: ""
    property string terminal: "ghostty -e"

    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/dms-clipboard-runner"
    readonly property var ctx: ({
            "downloads": downloadDir,
            "terminal": terminal
        })

    // getItems() has to answer synchronously, and the shell currently has no
    // hook for a launcher plugin to say "my list changed" -- neither
    // itemsChanged nor PluginService.requestLauncherUpdate is connected to
    // anything. So the clipboard is kept cached ahead of time rather than
    // fetched on demand: read once when the instance is created, and again
    // whenever the clipboard changes. That is one small socket round trip per
    // copy, and only after the runner has been used at least once, because the
    // instance itself is created lazily by ensureLauncherInstance().
    property var detail: null
    property bool reading: false
    property string readError: ""

    Component.onCompleted: {
        _seed();
        _loadSettings();
        _readClipboard();
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
        onTriggered: root._readClipboard()
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

    // Both of these are no-ops in the shell as it stands; they are here so the
    // plugin behaves correctly if a refresh hook is ever wired up. The list
    // staying correct does not depend on them -- see the note above.
    function _refreshLauncher() {
        itemsChanged();
        if (pluginService && typeof pluginService.requestLauncherUpdate === "function")
            pluginService.requestLauncherUpdate(pluginId);
    }

    // clipboard.paste hands back the full current clipboard as text, unlike the
    // history previews which stop at 100 characters. It fails for a clipboard
    // holding an image and nothing else, which is where _readImage takes over.
    function _readClipboard() {
        if (reading)
            return;
        if (!DMSService.isConnected) {
            detail = null;
            readError = "DMS is not connected";
            return;
        }

        reading = true;
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

            const file = root.cacheDir + "/clipboard-" + current.id + "." + root._extForMime(current.mimeType);
            Proc.runCommand("clipboardRunner.materialise", ["zsh", "-c", 'mkdir -p "${1:h}" || exit 1
if [ ! -s "$1" ]; then
    "${DMS_EXECUTABLE:-dms}" cl get "$2" | base64 -d > "$1" || exit 1
fi', "materialise", file, String(current.id)], function (output, exitCode) {
                if (exitCode !== 0) {
                    root._fail("Could not write the clipboard image out");
                    return;
                }
                root._settle(file);
            });
        });
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

    function _fail(message) {
        reading = false;
        detail = null;
        readError = message;
        _refreshLauncher();
    }

    function getItems(query) {
        if (actions.length === 0)
            return [_statusItem("settings", "No clipboard actions yet", "Add one in Settings → Plugins → Clipboard Runner")];

        // Only reachable before the first read has landed -- typing another
        // character re-runs this and by then the cache is warm.
        if (!detail && !readError) {
            _readClipboard();
            return [_statusItem("hourglass_empty", "Reading the clipboard…", "Type another character")];
        }

        if (!detail)
            return [_statusItem("content_paste_off", readError || "Nothing usable on the clipboard", "")];

        const matched = Clipboard.matchAll(actions, detail);
        const kind = Clipboard.groupLabel(detail.type).toLowerCase();

        if (matched.length === 0)
            return [_statusItem("filter_alt_off", "No " + kind + " action matches this", _clip())];

        const q = (query || "").trim().toLowerCase();
        const filtered = q.length === 0 ? matched : matched.filter(a => {
            return (a.name || "").toLowerCase().includes(q) || (a.command || "").toLowerCase().includes(q);
        });

        if (filtered.length === 0)
            return [_statusItem("search_off", "No action matches \"" + query + "\"", _clip())];

        return filtered.map((a, i) => ({
            id: "clip:" + detail.type + ":" + i + ":" + (a.name || ""),
            name: a.name || a.command || "Unnamed action",
            icon: a.icon || ("material:" + Clipboard.groupIcon(detail.type)),
            comment: Clipboard.preview(a, detail, root.ctx),
            action: "execute",
            categories: ["Clipboard"],
            actionEntry: a
        }));
    }

    function executeItem(item) {
        if (!item || !item.actionEntry || !detail)
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
                    Quickshell.execDetached(["dms", "cl", "copy", line]);
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
