import QtQuick
import Quickshell
import qs.Services

// Launcher provider for user-defined commands. Commands are added by name in
// the plugin's settings panel (ListSettingWithInput -> "commands" setting,
// each entry {name, command, icon}); this component just lists and runs them.
Item {
    id: root

    readonly property string pluginId: "commandRunner"

    property var pluginService: null
    property string trigger: "run "

    signal itemsChanged

    property var commands: []

    Component.onCompleted: _loadSettings()
    onPluginServiceChanged: _loadSettings()

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId !== root.pluginId)
                return;
            root._loadSettings();
            root.itemsChanged();
            if (root.pluginService && typeof root.pluginService.requestLauncherUpdate === "function")
                root.pluginService.requestLauncherUpdate(root.pluginId);
        }
    }

    function _loadSettings() {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData(pluginId, "trigger", "run ");
        const loaded = pluginService.loadPluginData(pluginId, "commands", []);
        commands = Array.isArray(loaded) ? loaded : [];
    }

    function getItems(query) {
        if (commands.length === 0) {
            return [_statusItem("settings", "No commands configured", "Add one in Settings → Plugins → Command Runner")];
        }

        const q = (query || "").trim().toLowerCase();
        const matches = q.length === 0 ? commands : commands.filter(c => {
            return (c.name || "").toLowerCase().includes(q) || (c.command || "").toLowerCase().includes(q);
        });

        if (matches.length === 0) {
            return [_statusItem("search_off", "No commands match \"" + query + "\"", "")];
        }

        return matches.map((c, i) => ({
            id: "cmd:" + i + ":" + (c.name || ""),
            name: c.name || c.command || "Unnamed command",
            icon: c.icon || "material:terminal",
            comment: c.command || "",
            action: "execute",
            categories: ["Commands"],
            commandEntry: c
        }));
    }

    function executeItem(item) {
        if (!item || !item.commandEntry)
            return;

        const entry = item.commandEntry;
        if (!entry.command || entry.command.trim().length === 0)
            return;

        Quickshell.execDetached(["sh", "-c", entry.command]);
        _toast("Running " + (entry.name || entry.command), entry.command);
    }

    function getContextMenuActions(item) {
        if (!item || !item.commandEntry)
            return [];

        const entry = item.commandEntry;
        return [
            {
                icon: "content_copy",
                text: "Copy command",
                action: () => {
                    Quickshell.execDetached(["dms", "cl", "copy", entry.command || ""]);
                    root._toast("Copied", entry.command || "");
                }
            }
        ];
    }

    function _statusItem(icon, name, comment) {
        return {
            id: "cmd:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: "noop",
            categories: ["Commands"]
        };
    }

    function _toast(title, body) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, body);
    }
}
