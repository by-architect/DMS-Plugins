import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Status-only: no popout here. Clicking opens the centered panel (shared
// "open" global var with ScreenCatcherDaemon.qml); the real UI lives there.
// While recording, this pill doubles as an always-visible status readout with
// its own inline stop button, independent of whether the panel is open.
PluginComponent {
    id: root

    PluginGlobalVar {
        id: openVar
        varName: "open"
        defaultValue: false
    }

    pillClickAction: () => openVar.set(true)

    horizontalBarPill: Component {
        StyledRect {
            width: pillContent.implicitWidth + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
            color: ScreenCatcherService.isRecording ? Theme.withAlpha(Theme.error, 0.16) : "transparent"

            Row {
                id: pillContent
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: ScreenCatcherService.isRecording ? "fiber_manual_record" : "screenshot_monitor"
                    color: ScreenCatcherService.isRecording ? Theme.error : Theme.surfaceText
                    size: root.iconSize
                    filled: ScreenCatcherService.isRecording
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: ScreenCatcherService.isRecording
                    text: ScreenCatcherService.elapsedLabel
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                }

                Rectangle {
                    id: stopButton
                    anchors.verticalCenter: parent.verticalCenter
                    visible: ScreenCatcherService.isRecording
                    width: root.iconSize + 8
                    height: width
                    radius: width / 2
                    color: stopArea.containsMouse ? Theme.errorHover : "transparent"

                    DankIcon {
                        anchors.centerIn: parent
                        name: "stop_circle"
                        color: Theme.error
                        size: root.iconSize
                        filled: true
                    }

                    MouseArea {
                        id: stopArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            ScreenCatcherService.stopRecording();
                            mouse.accepted = true;
                        }
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        StyledRect {
            width: parent.widgetThickness
            height: pillContent.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: ScreenCatcherService.isRecording ? Theme.withAlpha(Theme.error, 0.16) : "transparent"

            Column {
                id: pillContent
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: ScreenCatcherService.isRecording ? "fiber_manual_record" : "screenshot_monitor"
                    color: ScreenCatcherService.isRecording ? Theme.error : Theme.surfaceText
                    size: root.iconSize
                    filled: ScreenCatcherService.isRecording
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: ScreenCatcherService.isRecording
                    text: ScreenCatcherService.elapsedLabel
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    horizontalAlignment: Text.AlignHCenter
                }

                Rectangle {
                    id: vStopButton
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: ScreenCatcherService.isRecording
                    width: root.iconSize + 4
                    height: width
                    radius: width / 2
                    color: vStopArea.containsMouse ? Theme.errorHover : "transparent"

                    DankIcon {
                        anchors.centerIn: parent
                        name: "stop_circle"
                        color: Theme.error
                        size: root.iconSize - 4
                        filled: true
                    }

                    MouseArea {
                        id: vStopArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            ScreenCatcherService.stopRecording();
                            mouse.accepted = true;
                        }
                    }
                }
            }
        }
    }
}
