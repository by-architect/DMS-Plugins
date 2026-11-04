import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// The phone is one of SSH Hosts' hosts -- edited there, picked here.
PluginSettings {
    id: root

    pluginId: "phoneStatus"

    readonly property var sshDaemon: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        return instances["sshManager"] ?? null;
    }
    property var _settingsHosts: []
    readonly property var hostOptions: {
        const list = root.sshDaemon ? root.sshDaemon.hosts : root._settingsHosts;
        const hosts = Array.isArray(list) ? list.filter(h => h && h.id) : [];
        return [
            {
                "label": "None",
                "value": ""
            }
        ].concat(hosts.map(h => ({
                    "label": (h.name || h.host) + "  ·  " + (h.username ? h.username + "@" : "") + h.host + (h.port && String(h.port) !== "22" ? ":" + h.port : ""),
                    "value": h.id
                })));
    }

    function _load() {
        const list = root.pluginService ? root.pluginService.loadPluginData("sshManager", "hosts", []) : [];
        _settingsHosts = Array.isArray(list) ? list : [];
    }

    Component.onCompleted: Qt.callLater(_load)
    onPluginServiceChanged: _load()

    SelectionSetting {
        settingKey: "host"
        label: "Phone"
        description: "The phone's entry in SSH Hosts: Termux's sshd, with a key. Most of what is shown needs root (su) on the phone."
        options: root.hostOptions
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "pollSeconds"
        label: "Check every"
        description: "One ssh per check, only while the pill is on a bar. Opening the popout always checks at once."
        defaultValue: 60
        minimum: 30
        maximum: 900
        unit: " s"
    }

    ToggleSetting {
        settingKey: "showNotificationCount"
        label: "Notification count on the pill"
        description: "How many notifications are waiting on the phone, not counting ongoing ones like a running service"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showPhotos"
        label: "Newest photos"
        description: "The four newest photos and screenshots in the popout. Each is copied over once, while the popout is open, and kept in the shell's cache until a newer one takes its place."
        defaultValue: true
    }
}
