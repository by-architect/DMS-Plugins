import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// The machines are matrix's own list, never typed in here: this only keeps
// how often they are read, which of them to leave off the bar, and how the
// bar sits.
PluginSettings {
    id: root

    pluginId: "matrixBar"

    property var hidden: []

    function _load() {
        const h = root.loadValue("hiddenHosts", []);
        hidden = Array.isArray(h) ? h : [];
    }

    function setShownOnBar(name, on) {
        const next = hidden.filter(n => n !== name);
        if (!on)
            next.push(name);
        hidden = next;
        root.saveValue("hiddenHosts", next);
    }

    Component.onCompleted: Qt.callLater(_load)
    onPluginServiceChanged: _load()

    ToggleSetting {
        settingKey: "shown"
        label: "Show the bar"
        description: "Also `dms ipc call matrixBar toggle`, for a keybind. While it is hidden, no machine is read"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "computerSeconds"
        label: "Computers: read every"
        description: "Seconds between two snapshots from a computer, over the ssh that stays open. Disks and Syncthing are read every 30 s whatever this is"
        defaultValue: 5
        minimum: 2
        maximum: 60
        unit: " s"
        leftIcon: "computer"
    }

    SliderSetting {
        settingKey: "phoneSeconds"
        label: "Phones: read every"
        description: "Seconds between two snapshots from a phone. Each one asks Android for its signal and Wi-Fi, so less often saves its battery; missed calls every minute, the data counter every five"
        defaultValue: 15
        minimum: 5
        maximum: 300
        unit: " s"
        leftIcon: "smartphone"
    }

    SliderSetting {
        settingKey: "dataAllowanceGb"
        label: "Mobile data allowance"
        description: "GB a month, for the data ring's percentage when the phone itself has no data limit or warning set (Settings → Network → Data usage). 0: show the gigabytes used instead"
        defaultValue: 0
        minimum: 0
        maximum: 200
        unit: " GB"
        leftIcon: "data_usage"
    }

    SliderSetting {
        settingKey: "barWidth"
        label: "Bar width"
        description: "In pixels. 0 follows DankBar's own thickness, widened just enough for two bars and their numbers side by side"
        defaultValue: 0
        minimum: 0
        maximum: 96
        unit: " px"
        leftIcon: "width"
    }

    StringSetting {
        settingKey: "screen"
        label: "Screen"
        description: "The output to show the bar on (eDP-1, DP-2…). Empty: every screen"
        placeholder: "every screen"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "devicesFile"
        label: "Devices file"
        description: "A JSON list of machines in matrix's format. Empty: the one the installed matrix fans out to (or MATRIX_DEVICES_JSON_OVERRIDE)"
        placeholder: "from matrix"
        defaultValue: ""
    }

    Column {
        // Reparented into the settings column after creation, so no parent yet
        // on the first evaluation.
        width: parent ? parent.width : 0
        spacing: Theme.spacingS

        StyledText {
            text: "Machines on the bar"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: MatrixBarService.discoveryError !== "" ? MatrixBarService.discoveryError : "Every machine matrix fans out to is on the bar unless it is switched off here. Machines are added and removed in the matrix flake."
            font.pixelSize: Theme.fontSizeSmall
            color: MatrixBarService.discoveryError !== "" ? Theme.error : Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: MatrixBarService.allHosts

            DankToggle {
                required property var modelData

                width: parent.width
                text: modelData.name + (modelData.self ? " (this machine)" : "")
                description: (modelData.android ? "phone · " : "") + (modelData.self ? "read here" : (modelData.user ? modelData.user + "@" : "") + modelData.ip + ":" + modelData.port)
                checked: root.hidden.indexOf(modelData.name) < 0
                onToggled: isChecked => root.setShownOnBar(modelData.name, isChecked)
            }
        }

        StyledText {
            width: parent.width
            visible: MatrixBarService.allHosts.length === 0 && MatrixBarService.discoveryError === ""
            text: "No machines yet: they are read from matrix when the bar first shows."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }
}
