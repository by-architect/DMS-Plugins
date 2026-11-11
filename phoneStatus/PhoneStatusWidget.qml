import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "phone.js" as Phone

// The pill: signal, battery and the number of notifications waiting on the
// phone -- what a glance at the phone's status bar would tell. The rest is in
// the popout.
PluginComponent {
    id: root

    layerNamespacePlugin: "phone-status"

    readonly property var svc: PhoneStatusService
    readonly property var r: svc.result
    readonly property bool reachable: svc.online
    readonly property var battery: r ? r.battery : null
    readonly property bool lowBattery: battery !== null && isFinite(battery.level) && battery.level <= 15 && battery.state !== "charging"
    readonly property color accent: !reachable ? Theme.surfaceVariantText : (lowBattery ? Theme.error : Theme.surfaceText)
    readonly property int waiting: svc.showNotificationCount ? svc.notifications.length : 0
    readonly property string levelText: battery && isFinite(battery.level) ? battery.level + "%" : ""

    popoutWidth: 480

    pillRightClickAction: () => PhoneStatusService.refresh(true)

    Component.onCompleted: PhoneStatusService.consumers++
    Component.onDestruction: PhoneStatusService.consumers = Math.max(0, PhoneStatusService.consumers - 1)

    horizontalBarPill: Component {
        StyledRect {
            implicitWidth: pillRow.implicitWidth + Theme.spacingS * 2
            implicitHeight: root.widgetThickness
            radius: height / 2
            color: root.lowBattery ? Theme.withAlpha(Theme.error, 0.16) : "transparent"

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !root.reachable
                    name: PhoneStatusService.host ? "mobile_off" : "smartphone"
                    size: root.iconSize
                    color: root.accent
                }

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.reachable
                    name: Phone.signalIcon(root.r ? root.r.cell : null, root.r && root.r.settings.airplane === "1")
                    size: root.iconSize - 2
                    color: root.accent
                }

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.reachable && root.battery !== null
                    name: Phone.batteryIcon(root.battery)
                    size: root.iconSize
                    color: root.accent
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.reachable && root.levelText !== ""
                    text: root.levelText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root.accent
                }

                // Notifications waiting on the phone.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.reachable && root.waiting > 0
                    width: Math.max(height, countText.implicitWidth + 8)
                    height: Theme.fontSizeSmall + 4
                    radius: height / 2
                    color: Theme.primary

                    StyledText {
                        id: countText

                        anchors.centerIn: parent
                        text: root.waiting > 99 ? "99+" : root.waiting
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.weight: Font.Bold
                        color: Theme.primaryText
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: root.widgetThickness
            implicitHeight: vColumn.implicitHeight

            Column {
                id: vColumn

                anchors.centerIn: parent
                spacing: 1

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: root.reachable ? Phone.batteryIcon(root.battery) : "mobile_off"
                    size: root.iconSize
                    color: root.accent
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.reachable && root.levelText !== ""
                    text: root.levelText
                    font.pixelSize: Theme.fontSizeSmall - 2
                    color: root.accent
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.reachable && root.waiting > 0
                    width: 6
                    height: 6
                    radius: 3
                    color: Theme.primary
                }
            }
        }
    }

    popoutContent: Component {
        PhoneStatusPopout {}
    }
}
