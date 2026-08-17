import QtQuick
import qs.Common
import qs.Widgets

// One row in a category's filter builder: [field] [mode] "text" [remove].
// Emits the updated {field, mode, value} object on every edit — the parent
// owns the actual conditions array and reassigns it, so this stays a plain,
// stateless editor over whatever condition it's given.
Column {
    id: root

    required property var condition
    property bool removable: true

    signal changed(var condition)
    signal removeRequested

    readonly property var fieldLabels: ["Any field", "Title", "Content", "App", "Urgency"]
    readonly property var fieldKeys: ["any", "title", "content", "app", "urgency"]
    readonly property var modeLabels: ["Include", "Exact match", "Exclude"]
    readonly property var modeKeys: ["include", "exact", "exclude"]

    function fieldLabel(key) {
        const i = fieldKeys.indexOf(key);
        return fieldLabels[i === -1 ? 0 : i];
    }

    function modeLabel(key) {
        const i = modeKeys.indexOf(key);
        return modeLabels[i === -1 ? 0 : i];
    }

    function update(patch) {
        root.changed(Object.assign({}, root.condition, patch));
    }

    spacing: 4

    Row {
        width: parent.width
        spacing: Theme.spacingXS

        DankDropdown {
            dropdownWidth: 96
            popupWidth: 96
            options: root.fieldLabels
            currentValue: root.fieldLabel(root.condition.field)
            onValueChanged: value => root.update({
                    "field": root.fieldKeys[root.fieldLabels.indexOf(value)]
                })
        }

        DankDropdown {
            dropdownWidth: 104
            popupWidth: 104
            options: root.modeLabels
            currentValue: root.modeLabel(root.condition.mode)
            onValueChanged: value => root.update({
                    "mode": root.modeKeys[root.modeLabels.indexOf(value)]
                })
        }

        DankActionButton {
            iconName: "close"
            iconSize: 14
            visible: root.removable
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.removeRequested()
        }
    }

    DankTextField {
        width: parent.width
        placeholderText: "text to match"
        text: root.condition.value || ""
        onTextEdited: root.update({
                "value": text
            })
    }
}
