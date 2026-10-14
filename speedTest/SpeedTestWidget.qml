import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "speedtest.js" as Speed

// The pill is the last test's speeds -- "↓94 ↑12" in Mbit/s -- amber when
// the download is under the slow level, red with no number when the last
// test failed and none ever worked. While a test runs, a spinner takes the
// icon's place. Left-click is the popout; right-click runs a test now.
PluginComponent {
    id: root

    layerNamespacePlugin: "speed-test"

    readonly property var last: SpeedTestService.last
    readonly property bool running: SpeedTestService.running
    readonly property bool broken: SpeedTestService.lastFailed && !last
    readonly property color accent: broken ? Theme.error : (SpeedTestService.slow ? Theme.tempWarning : Theme.widgetIconColor)
    readonly property color textColor: broken || SpeedTestService.slow ? accent : Theme.widgetTextColor
    readonly property string iconName: broken ? "signal_wifi_bad" : "speed"

    popoutWidth: 440

    pillRightClickAction: () => SpeedTestService.run("manual")

    // Counted in and out, so tests only run on the timer while a pill exists.
    Component.onCompleted: SpeedTestService.consumers++
    Component.onDestruction: SpeedTestService.consumers = Math.max(0, SpeedTestService.consumers - 1)

    horizontalBarPill: Component {
        StyledRect {
            // Implicit size only: BasePill reads implicitWidth/implicitHeight
            // and adds the bar's own padding. widgetThickness comes from root,
            // not from `parent` (BasePill's Loader).
            implicitWidth: pillRow.implicitWidth + Theme.spacingS * 2
            implicitHeight: root.widgetThickness
            radius: height / 2
            color: root.broken || SpeedTestService.slow ? Theme.withAlpha(root.accent, 0.16) : "transparent"

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.iconSize
                    height: root.iconSize

                    DankIcon {
                        anchors.centerIn: parent
                        name: root.iconName
                        size: root.iconSize
                        color: root.accent
                        visible: !root.running
                    }

                    DankSpinner {
                        anchors.centerIn: parent
                        size: root.iconSize - 2
                        color: Theme.primary
                        running: root.running
                        visible: root.running
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Speed.pillText(root.last, SpeedTestService.pillShows)
                    font.pixelSize: root.textSize
                    font.features: ({
                            "tnum": 1
                        })
                    wrapMode: Text.NoWrap
                    color: root.textColor
                    opacity: root.running ? 0.55 : 1
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

                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: root.iconSize + 10
                    height: width

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: root.broken || SpeedTestService.slow ? Theme.withAlpha(root.accent, 0.16) : "transparent"
                    }

                    DankIcon {
                        anchors.centerIn: parent
                        name: root.iconName
                        size: root.iconSize
                        color: root.accent
                        visible: !root.running
                    }

                    DankSpinner {
                        anchors.centerIn: parent
                        size: root.iconSize - 2
                        color: Theme.primary
                        running: root.running
                        visible: root.running
                    }
                }

                // The download only: there is no room for both across a
                // vertical bar.
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.last ? Speed.shortMbps(root.last.down) : "--"
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.features: ({
                            "tnum": 1
                        })
                    wrapMode: Text.NoWrap
                    color: root.textColor
                }
            }
        }
    }

    popoutContent: Component {
        SpeedTestPopout {}
    }
}
