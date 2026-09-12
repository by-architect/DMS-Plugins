import QtQuick
import Quickshell
import qs.Common
import qs.Services

// Launcher provider for the host list configured in this plugin's settings
// (see SSHManagerSettings.qml). Reads settings directly rather than through
// the daemon instance, so opening a connection doesn't depend on daemon
// startup timing -- the only thing the daemon owns that this launcher
// doesn't need is stored passwords, and password auth is always interactive
// here (ssh prompts for it itself once the terminal opens).
Item {
    id: root

    readonly property string pluginId: "sshManager"

    property var pluginService: null
    property string trigger: "ssh "

    signal itemsChanged

    property var hosts: []
    property string terminalBin: "ghostty"
    property string terminalArgsOverride: ""

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
        trigger = pluginService.loadPluginData(pluginId, "trigger", "ssh ");
        terminalBin = pluginService.loadPluginData(pluginId, "terminalBin", "ghostty");
        terminalArgsOverride = pluginService.loadPluginData(pluginId, "terminalArgsOverride", "");
        const loaded = pluginService.loadPluginData(pluginId, "hosts", []);
        hosts = Array.isArray(loaded) ? loaded : [];
    }

    function getItems(query) {
        if (hosts.length === 0) {
            return [_statusItem("settings", "No SSH hosts configured", "Add one in Settings → Plugins → SSH Hosts")];
        }

        const q = (query || "").trim().toLowerCase();
        const matches = q.length === 0 ? hosts : hosts.filter(h => {
            return (h.name || "").toLowerCase().includes(q) || (h.host || "").toLowerCase().includes(q) || (h.username || "").toLowerCase().includes(q);
        });

        if (matches.length === 0) {
            return [_statusItem("search_off", "No hosts match \"" + query + "\"", "")];
        }

        return matches.map(h => _hostItem(h));
    }

    function executeItem(item) {
        if (!item || !item.hostEntry)
            return;
        _connect(item.hostEntry);
    }

    function getContextMenuActions(item) {
        if (!item || !item.hostEntry)
            return [];

        const entry = item.hostEntry;
        const dest = entry.username ? (entry.username + "@" + entry.host) : entry.host;
        return [{
            icon: "content_copy",
            text: "Copy connection string",
            action: () => {
                Quickshell.execDetached(["dms", "cl", "copy", "ssh://" + dest + (entry.port && entry.port !== "22" ? ":" + entry.port : "")]);
                root._toast("Copied", dest);
            }
        }];
    }

    function _hostItem(h) {
        const dest = h.username ? (h.username + "@" + h.host) : h.host;
        const portSuffix = h.port && h.port !== "22" ? ":" + h.port : "";
        const authNote = h.authMethod === "password" ? (h.hasPassword ? "password stored, prompted at connect" : "password (not stored)") : (h.identityFile ? "key: " + h.identityFile : "key (default identity)");
        return {
            id: "ssh:" + h.id,
            name: h.name || dest,
            icon: h.authMethod === "password" ? "material:lock" : "material:vpn_key",
            comment: dest + portSuffix + " · " + authNote,
            action: "connect",
            categories: ["SSH Hosts"],
            hostEntry: h
        };
    }

    function _statusItem(icon, name, comment) {
        return {
            id: "ssh:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: "noop",
            categories: ["SSH Hosts"]
        };
    }

    function _connect(h) {
        if (!h || !h.host) {
            return;
        }
        const argv = ["ssh"];
        if (h.port && h.port !== "22")
            argv.push("-p", h.port);
        if (h.authMethod === "key" && h.identityFile)
            argv.push("-i", Paths.expandTilde(h.identityFile));
        argv.push(h.username ? (h.username + "@" + h.host) : h.host);

        Quickshell.execDetached(_terminalPrefix().concat(argv));
        root._toast("Connecting", (h.name || h.host));
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
}
