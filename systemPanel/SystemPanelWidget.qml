import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Bar pill that toggles the fullscreen panel. Shares the "open" global var with
// the daemon, so the pill also reflects panel state opened over IPC.
PluginComponent {
    id: root

    PluginGlobalVar {
        id: openVar

        varName: "open"
        defaultValue: false
    }

    pillClickAction: function () {
        openVar.set(openVar.value !== true);
    }

    horizontalBarPill: Component {
        StyledRect {
            readonly property bool active: openVar.value === true

            width: pillRow.implicitWidth + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
            color: active ? Theme.primaryBackground : Theme.surfaceContainerHigh

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: "monitor_heart"
                    size: root.iconSize
                    color: parent.parent.active ? Theme.primary : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Component {
        StyledRect {
            readonly property bool active: openVar.value === true

            width: parent.widgetThickness
            height: width
            radius: Theme.cornerRadius
            color: active ? Theme.primaryBackground : Theme.surfaceContainerHigh

            DankIcon {
                anchors.centerIn: parent
                name: "monitor_heart"
                size: root.iconSize
                color: parent.active ? Theme.primary : Theme.surfaceText
            }
        }
    }
}
