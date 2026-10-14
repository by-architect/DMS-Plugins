import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "procstat.js" as Stat

// The pill is one number, and its icon says which one. In priority order:
//
//   terminal    one process is using too much (100% = one whole core)
//   view_week   one core is too busy
//   memory      the whole machine -- also what it shows when all is quiet
//
// "Too much" is the alert levels in the settings, held for two samples in a
// row (see ProcessWidgetService). The colour carries the level and a hairline
// along the bottom the whole machine's usage; the popout says which process
// or core it is.
PluginComponent {
    id: root

    layerNamespacePlugin: "process-widget"

    readonly property real cpu: ProcessWidgetService.cpu
    readonly property var pill: ProcessWidgetService.pill
    readonly property int level: pill.level
    readonly property bool alarmed: level > 0
    readonly property string iconName: Stat.pillIcon(pill.kind)
    readonly property real shownValue: pill.value
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
                    name: root.iconName
                    size: root.iconSize
                    color: root.accent
                    filled: root.alarmed
                }

                // Room for two digits is kept whatever the number, so the
                // pills beside this one do not shift every time it crosses 10%.
                // A process past one core reads three digits (150%).
                NumericText {
                    anchors.verticalCenter: parent.verticalCenter
                    isMonospace: false
                    font.features: ({
                            "tnum": 1
                        })
                    text: Stat.percentText(root.shownValue)
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
                        name: root.iconName
                        size: root.iconSize
                        color: root.accent
                        filled: root.alarmed
                    }
                }

                // No room for the % sign across a vertical bar.
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.shownValue >= 0 ? Math.round(root.shownValue) : "--"
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
