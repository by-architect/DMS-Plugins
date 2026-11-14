import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// The phone is one of SSH Hosts' hosts -- edited there, picked here.
PluginSettings {
    id: root

    pluginId: "callRunner"

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
                "label": "Phone Status's phone",
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

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "What turns the launcher into this one. The space after it keeps other words from matching."
        placeholder: "call "
        defaultValue: "call "
    }

    SelectionSetting {
        settingKey: "host"
        label: "Phone"
        description: "The phone's entry in SSH Hosts, with a key. Reading the contacts and calling need root (su) on the phone."
        options: root.hostOptions
        defaultValue: ""
    }

    StringSetting {
        settingKey: "adbSerial"
        label: "adb serial"
        description: "When ssh cannot reach the phone, adb is tried with a USB cable -- only the device with this serial. Empty: the phone's own, learned over ssh."
        placeholder: "learned over ssh"
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "refreshMinutes"
        label: "Read the contacts again after"
        description: "Opening the launcher reads them in the background when they are older than this. Type \"call refresh\" to read them now."
        defaultValue: 15
        minimum: 1
        maximum: 240
        unit: " min"
    }

    SliderSetting {
        settingKey: "recentCount"
        label: "Newest calls shown"
        description: "With nothing typed, the people called last come first, one row each."
        defaultValue: 8
        minimum: 0
        maximum: 30
    }

    SliderSetting {
        settingKey: "maxResults"
        label: "Results shown"
        defaultValue: 40
        minimum: 10
        maximum: 200
    }
}
