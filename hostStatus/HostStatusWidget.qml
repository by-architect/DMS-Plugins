import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// The pill answers one question: is everything up? An icon and "up/total",
// amber when some host is down, red when none answered. The rest is in the
// popout.
PluginComponent {
    id: root

    layerNamespacePlugin: "host-status"

    readonly property int up: HostStatusService.upCount
    readonly property int total: HostStatusService.total
    readonly property int down: HostStatusService.downCount
    readonly property bool trouble: down > 0
    readonly property color accent: !trouble ? Theme.surfaceVariantText : (up === 0 ? Theme.error : Theme.warning)
    // "?" until the first answer is in, rather than a "0/4" that reads as
    // everything being down.
    readonly property string pillText: total > 0 ? (HostStatusService.lastCheckedMs > 0 ? up : "?") + "/" + total : ""

    popoutWidth: 480

    // Right-click checks every host now; left-click is the popout.
    pillRightClickAction: () => HostStatusService.refreshAll(true)

    // Counted in and out, so the service only polls while a pill exists.
    Component.onCompleted: HostStatusService.consumers++
    Component.onDestruction: HostStatusService.consumers = Math.max(0, HostStatusService.consumers - 1)

    horizontalBarPill: Component {
        StyledRect {
            // Implicit size only: BasePill reads implicitWidth/implicitHeight
            // and adds the bar's own padding. widgetThickness comes from root,
            // not from `parent` (BasePill's Loader).
            implicitWidth: pillRow.implicitWidth + Theme.spacingS * 2
            implicitHeight: root.widgetThickness
            radius: height / 2
            color: root.trouble ? Theme.withAlpha(root.accent, 0.16) : "transparent"

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "dns"
                    size: root.iconSize
                    color: root.accent
                    filled: root.trouble
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.pillText.length > 0
                    text: root.pillText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root.accent
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: root.widgetThickness
            implicitHeight: vPillContent.implicitHeight

            Column {
                id: vPillContent

                anchors.centerIn: parent
                spacing: 1

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: root.iconSize + 10
                    height: width
                    radius: width / 2
                    color: root.trouble ? Theme.withAlpha(root.accent, 0.16) : "transparent"

                    DankIcon {
                        anchors.centerIn: parent
                        name: "dns"
                        size: root.iconSize
                        color: root.accent
                        filled: root.trouble
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.pillText.length > 0
                    text: root.pillText
                    font.pixelSize: Theme.fontSizeSmall - 2
                    color: root.accent
                }
            }
        }
    }

    popoutContent: Component {
        HostStatusPopout {}
    }
}
