import QtQuick
import Quickshell
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
    // history previews which stop at 100 characters. It reports an error for an
    // image-only clipboard, which is shown as-is.
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
            root.reading = false;

            if (response.error) {
                root.detail = null;
                root.readError = response.error;
            } else {
                const text = (response.result && response.result.text) || "";
                if (text.trim().length === 0) {
                    root.detail = null;
                    root.readError = "Clipboard has no text on it";
                } else {
                    root.detail = Clipboard.describe(text);
                    root.readError = "";
                }
            }
            root._refreshLauncher();
        });
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
