import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "procstat.js" as Stat

// The pill is one number: how busy the whole machine is, read from /proc/stat.
// Its colour carries the thresholds and a hairline along the bottom its
// length; per-core bars, memory, load and the processes are in the popout.
PluginComponent {
    id: root

    layerNamespacePlugin: "process-widget"

    readonly property real cpu: ProcessWidgetService.cpu
    readonly property int level: ProcessWidgetService.level
    readonly property bool alarmed: level > 0
    readonly property color accent: level === 2 ? Theme.tempDanger : (level === 1 ? Theme.tempWarning : Theme.widgetIconColor)
    readonly property color textColor: alarmed ? accent : Theme.widgetTextColor
    readonly property real fraction: cpu > 0 ? Math.min(1, cpu / 100) : 0

    popoutWidth: 460

    // Counted in and out, so the service only samples while a pill exists.
    Component.onCompleted: ProcessWidgetService.consumers++
    Component.onDestruction: ProcessWidgetService.consumers = Math.max(0, ProcessWidgetService.consumers - 1)

    horizontalBarPill: Component {
        StyledRect {
            // The pill's size on the bar comes from these IMPLICIT values:
            // BasePill reads implicitWidth/implicitHeight and adds the bar's
            // own widget padding around them. Setting width/height instead
            // leaves the implicit size at zero and the pill collapses to bare
            // padding. `parent` here is BasePill's Loader, which has no
            // widgetThickness — that comes from root.
            implicitWidth: pillRow.implicitWidth + Theme.spacingS * 2
            implicitHeight: root.widgetThickness
            radius: height / 2
            color: root.alarmed ? Theme.withAlpha(root.accent, 0.16) : "transparent"

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "memory"
                    size: root.iconSize
                    color: root.accent
                    filled: root.alarmed
                }

                // Room for two digits is kept whatever the number, so the
                // pills beside this one do not shift every time it crosses 10%.
                NumericText {
                    anchors.verticalCenter: parent.verticalCenter
                    isMonospace: false
                    font.features: ({
                            "tnum": 1
                        })
                    text: Stat.percentText(root.cpu)
                    reserveText: "00%"
                    width: Math.ceil(Math.max(implicitWidth, reservedWidth))
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: root.textSize
                    color: root.textColor
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.spacingS
                anchors.bottomMargin: 3
                width: (parent.width - Theme.spacingS * 2) * root.fraction
                height: 2
                radius: 1
                color: root.accent
                opacity: root.alarmed ? 1 : 0.6
                visible: ProcessWidgetService.showBar && root.fraction > 0

                Behavior on width {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            // Implicit size only — see the horizontal pill. The icon sits in a
            // round well of its own rather than colouring the whole pill.
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
                    color: root.alarmed ? Theme.withAlpha(root.accent, 0.16) : "transparent"

                    DankIcon {
                        anchors.centerIn: parent
                        name: "memory"
                        size: root.iconSize
                        color: root.accent
                        filled: root.alarmed
                    }
                }

                // No room for the % sign across a vertical bar.
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.cpu >= 0 ? Math.round(root.cpu) : "--"
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.features: ({
                            "tnum": 1
                        })
                    color: root.textColor
                }
            }
        }
    }

    popoutContent: Component {
        ProcessWidgetPopout {}
    }
}
