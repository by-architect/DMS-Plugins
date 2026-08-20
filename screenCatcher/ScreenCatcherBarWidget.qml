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
                    id: recIcon
                    anchors.verticalCenter: parent.verticalCenter
                    name: ScreenCatcherService.isRecording ? "fiber_manual_record" : "screenshot_monitor"
                    color: ScreenCatcherService.isRecording ? Theme.error : Theme.surfaceText
                    size: root.iconSize
                    filled: ScreenCatcherService.isRecording

                    SequentialAnimation on opacity {
                        running: ScreenCatcherService.isRecording
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) recIcon.opacity = 1
                        NumberAnimation {
                            to: 0.35
                            duration: 600
                            easing.type: Easing.InOutQuad
                        }
                        NumberAnimation {
                            to: 1
                            duration: 600
                            easing.type: Easing.InOutQuad
                        }
                    }
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

    // The vertical pill deliberately carries no stop button: icon + timer +
    // a round stop button stacked vertically came out taller than the bar's
    // own thickness, so the pill grew past its slot and overlapped the widget
    // above it. Clicking the pill opens the panel, where X stops the
    // recording; the horizontal pill has the room for an inline stop and
    // keeps it.
    verticalBarPill: Component {
        StyledRect {
            width: parent.widgetThickness
            height: vPillContent.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: ScreenCatcherService.isRecording ? Theme.withAlpha(Theme.error, 0.16) : "transparent"

            Column {
                id: vPillContent
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    id: vRecIcon
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: ScreenCatcherService.isRecording ? "fiber_manual_record" : "screenshot_monitor"
                    color: ScreenCatcherService.isRecording ? Theme.error : Theme.surfaceText
                    size: root.iconSize
                    filled: ScreenCatcherService.isRecording

                    SequentialAnimation on opacity {
                        running: ScreenCatcherService.isRecording
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) vRecIcon.opacity = 1
                        NumberAnimation {
                            to: 0.35
                            duration: 600
                            easing.type: Easing.InOutQuad
                        }
                        NumberAnimation {
                            to: 1
                            duration: 600
                            easing.type: Easing.InOutQuad
                        }
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: ScreenCatcherService.isRecording
                    text: ScreenCatcherService.elapsedLabel
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }
}
