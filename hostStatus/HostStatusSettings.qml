import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "hosts.js" as Hosts

// The host list itself is SSH Hosts' -- edited there, never copied here. All
// this keeps is which of those hosts to leave out, so a host added there
// later is watched by default.
PluginSettings {
    id: root

    pluginId: "hostStatus"

    readonly property var sshDaemon: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        return instances["sshManager"] ?? null;
    }
    property var _settingsHosts: []
    readonly property var sshHosts: {
        const list = root.sshDaemon ? root.sshDaemon.hosts : root._settingsHosts;
        return Array.isArray(list) ? list.filter(h => h && h.id) : [];
    }
    property var excluded: []

    function _load() {
        const ex = root.loadValue("excludedHosts", []);
        excluded = Array.isArray(ex) ? ex : [];
        const list = root.pluginService ? root.pluginService.loadPluginData("sshManager", "hosts", []) : [];
        _settingsHosts = Array.isArray(list) ? list : [];
    }

    function setWatched(hostId, watched) {
        const next = excluded.filter(id => id !== hostId);
        if (!watched)
            next.push(hostId);
        excluded = next;
        root.saveValue("excludedHosts", next);
    }

    Component.onCompleted: Qt.callLater(_load)
    onPluginServiceChanged: _load()

    Connections {
        target: root.pluginService

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId || changedPluginId === "sshManager")
                root._load();
        }
    }

    SliderSetting {
        settingKey: "pollSeconds"
        label: "Check every"
        description: "How often each host is checked, one ssh per host, four at a time. Only while the pill is on a bar"
        defaultValue: 60
        minimum: 15
        maximum: 900
        unit: " s"
        leftIcon: "schedule"
    }

    ToggleSetting {
        settingKey: "showStorage"
        label: "Show storage"
        description: "One bar per real filesystem on each host (/ first; tmpfs, overlay, snaps and network mounts left out)"
        defaultValue: true
    }

    Column {
        // Reparented into the settings column after creation, so no parent yet
        // on the first evaluation.
        width: parent ? parent.width : 0
        spacing: Theme.spacingS

        StyledText {
            text: "Hosts to watch"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: "Every host in SSH Hosts is watched unless it is switched off here. Add, edit or remove hosts in SSH Hosts' own settings."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: root.sshHosts.length

            DankToggle {
                required property int index
                readonly property var entry: root.sshHosts[index]

                width: parent.width
                text: entry ? (entry.name || entry.host) : ""
                description: entry ? Hosts.destText(entry) + (entry.authMethod === "password" ? " · password (needs sshpass)" : "") : ""
                checked: entry ? root.excluded.indexOf(entry.id) < 0 : false
                onToggled: isChecked => {
                    if (entry)
                        root.setWatched(entry.id, isChecked);
                }
            }
        }

        StyledText {
            width: parent.width
            visible: root.sshHosts.length === 0
            text: "No hosts yet. Enable SSH Hosts and add some in its settings."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }
}
