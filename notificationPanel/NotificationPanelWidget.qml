import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Bar pill that toggles the fullscreen panel, and shows a badge for how many
// notifications currently exist. Shares the "open" global var with the daemon.
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
            readonly property int count: NotificationService.historyList.length

            width: pillRow.implicitWidth + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
            color: active ? Theme.primaryBackground : Theme.surfaceContainerHigh

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: "notifications"
                    size: root.iconSize
                    color: parent.parent.active ? Theme.primary : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: parent.parent.count
                    font.pixelSize: Theme.fontSizeSmall
                    color: parent.parent.active ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.parent.count > 0
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
                name: "notifications"
                size: root.iconSize
                color: parent.active ? Theme.primary : Theme.surfaceText
            }
        }
    }
}
