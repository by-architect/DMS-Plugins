import QtQuick
import Quickshell
import qs.Common
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

    // ---- the phone ------------------------------------------------------
    //
    // A phone set up under Settings -> Phone gets commands of its own, run by
    // scripts/phone.sh over adb: "run logos hotspot" turns its hotspot on and
    // joins it. The script reports every outcome as a notification.
    property string phoneName: ""
    property string phoneAddress: ""
    property string phoneHotspot: ""

    readonly property string phoneScript: decodeURIComponent(Qt.resolvedUrl("scripts/phone.sh").toString().replace(/^file:\/\//, ""))

    readonly property var phoneActions: [
        {
            "id": "hotspot-on",
            "name": "Hotspot on, and connect",
            "comment": "Turns on %1's hotspot and joins it",
            "icon": "wifi_tethering",
            "words": "internet share tether wifi wlan join"
        },
        {
            "id": "hotspot-off",
            "name": "Hotspot off",
            "comment": "Turns %1's hotspot off",
            "icon": "portable_wifi_off",
            "words": "internet share tether wifi stop"
        },
        {
            "id": "mirror",
            "name": "Show screen",
            "comment": "%1's screen in a window, mouse and keyboard included (scrcpy)",
            "icon": "cast",
            "words": "mirror scrcpy control remote"
        },
        {
            "id": "screenshot",
            "name": "Screenshot",
            "comment": "A screenshot of %1, on the clipboard and in Pictures/Screenshots",
            "icon": "screenshot_monitor",
            "words": "capture screen picture"
        },
        {
            "id": "photo",
            "name": "Get newest photo",
            "comment": "The newest photo or screenshot on %1, on the clipboard and in Downloads",
            "icon": "photo_library",
            "words": "picture image camera pull fetch"
        },
        {
            "id": "send",
            "name": "Send newest download",
            "comment": "The newest file in Downloads, to %1's Download folder",
            "icon": "send_to_mobile",
            "words": "push file upload transfer"
        },
        {
            "id": "link",
            "name": "Open clipboard link",
            "comment": "Opens the link on the clipboard on %1",
            "icon": "open_in_browser",
            "words": "url browser web"
        },
        {
            "id": "battery",
            "name": "Battery",
            "comment": "%1's battery level, charging and temperature",
            "icon": "battery_charging_full",
            "words": "charge power status level"
        },
        {
            "id": "dnd",
            "name": "Do Not Disturb on/off",
            "comment": "Silences %1, or lets it ring again",
            "icon": "do_not_disturb_on",
            "words": "silent mute quiet dnd"
        },
        {
            "id": "lock",
            "name": "Lock screen",
            "comment": "Turns %1's screen off",
            "icon": "lock",
            "words": "sleep screen off"
        },
        {
            "id": "connect",
            "name": "Connect adb",
            "comment": "Reaches %1 over adb, and turns on wireless adb when it is on a cable",
            "icon": "phonelink",
            "words": "adb wireless debugging usb cable"
        }
    ]

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
        phoneName = String(pluginService.loadPluginData(pluginId, "phoneName", "") || "").trim();
        phoneAddress = String(pluginService.loadPluginData(pluginId, "phoneAddress", "") || "").trim();
        phoneHotspot = String(pluginService.loadPluginData(pluginId, "phoneHotspot", "") || "").trim();
    }

    // Every word of the query starts a word of the name, the description or
    // the extra words: "logos hot", "hotspot", "phone battery" -- and "hot" is
    // not in "screenshot".
    function _phoneItems(query) {
        if (phoneName === "")
            return [];
        const words = (query || "").trim().toLowerCase().split(/\s+/).filter(w => w !== "");
        return phoneActions.filter(a => {
            const hay = [phoneName, "phone android", a.name, a.comment.arg(phoneName), a.words].join(" ").toLowerCase().split(/[\s:,.()\/'’]+/);
            return words.every(w => hay.some(h => h.startsWith(w)));
        }).map(a => ({
                    id: "phone:" + a.id,
                    name: phoneName + ": " + a.name,
                    icon: "material:" + a.icon,
                    comment: a.comment.arg(phoneName),
                    action: "execute",
                    categories: ["Commands"],
                    phoneAction: a
                }));
    }

    function _phoneCommand(action) {
        return ["env", "PHONE_NAME=" + phoneName, "PHONE_ADDRESS=" + phoneAddress, "PHONE_HOTSPOT=" + phoneHotspot, "bash", phoneScript, action];
    }

    // The same as a line for a terminal or a compositor keybind.
    function _phoneCommandLine(action) {
        const q = v => "'" + String(v).replace(/'/g, "'\\''") + "'";
        return "PHONE_NAME=" + q(phoneName) + " PHONE_ADDRESS=" + q(phoneAddress) + " PHONE_HOTSPOT=" + q(phoneHotspot) + " bash " + q(phoneScript) + " " + action;
    }

    function getItems(query) {
        if (commands.length === 0 && phoneName === "") {
            return [_statusItem("settings", "No commands configured", "Add one in Settings → Plugins → Command Runner")];
        }

        const q = (query || "").trim().toLowerCase();
        const matches = q.length === 0 ? commands : commands.filter(c => {
            return (c.name || "").toLowerCase().includes(q) || (c.command || "").toLowerCase().includes(q);
        });
        const phone = _phoneItems(query);

        if (matches.length === 0 && phone.length === 0) {
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
        })).concat(phone);
    }

    function executeItem(item) {
        if (item && item.phoneAction) {
            Quickshell.execDetached(_phoneCommand(item.phoneAction.id));
            _toast(item.name, "");
            return;
        }
        if (!item || !item.commandEntry)
            return;

        const entry = item.commandEntry;
        if (!entry.command || entry.command.trim().length === 0)
            return;

        Quickshell.execDetached(["sh", "-c", entry.command]);
        _toast("Running " + (entry.name || entry.command), entry.command);
    }

    function getContextMenuActions(item) {
        if (item && item.phoneAction) {
            const line = _phoneCommandLine(item.phoneAction.id);
            return [
                {
                    icon: "content_copy",
                    text: "Copy command",
                    action: () => {
                        Quickshell.execDetached([Proc.dmsBin, "cl", "copy", line]);
                        root._toast("Copied", line);
                    }
                }
            ];
        }
        if (!item || !item.commandEntry)
            return [];

        const entry = item.commandEntry;
        return [
            {
                icon: "content_copy",
                text: "Copy command",
                action: () => {
                    // Proc.dmsBin, not a bare "dms": the shell hands its
                    // children $DMS_EXECUTABLE, but doesn't always have dms
                    // itself on PATH.
                    Quickshell.execDetached([Proc.dmsBin, "cl", "copy", entry.command || ""]);
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
