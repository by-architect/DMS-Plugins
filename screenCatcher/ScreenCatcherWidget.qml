import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    popoutWidth: 480
    popoutHeight: 420

    // -------------------------------------------------------------- bar pill

    horizontalBarPill: Component {
        StyledRect {
            id: pill
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
                    name: ScreenCatcherService.isRecording ? "fiber_manual_record" : (ScreenCatcherService.isSelecting ? "crop" : "screenshot_monitor")
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
                        onClicked: ScreenCatcherService.stopRecording()
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
                    name: ScreenCatcherService.isRecording ? "fiber_manual_record" : (ScreenCatcherService.isSelecting ? "crop" : "screenshot_monitor")
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
                        onClicked: ScreenCatcherService.stopRecording()
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------- popout

    popoutContent: Component {
        PopoutComponent {
            id: popoutColumn

            headerText: "Screen Catcher"
            detailsText: ScreenCatcherService.isRecording ? "Recording " + ScreenCatcherService.recordingLabel + " · " + ScreenCatcherService.elapsedLabel : "Capture, OCR and record your screen"
            showCloseButton: true

            readonly property var screenshotActions: [
                {
                    icon: "crop",
                    label: "Screenshot Selected",
                    action: () => ScreenCatcherService.takeScreenshotSelected()
                },
                {
                    icon: "fullscreen",
                    label: "Screenshot Fullscreen",
                    action: () => ScreenCatcherService.takeScreenshotFullscreen()
                },
                {
                    icon: "text_fields",
                    label: "Screenshot to Text",
                    action: () => ScreenCatcherService.screenshotToText()
                }
            ]

            readonly property var recordActions: [
                {
                    icon: "screen_record",
                    label: "Record Fullscreen",
                    action: () => ScreenCatcherService.startRecording("full")
                },
                {
                    icon: "crop_free",
                    label: "Record Selected",
                    action: () => ScreenCatcherService.startRecording("select")
                },
                {
                    icon: "gif_box",
                    label: "Record Selected as GIF",
                    action: () => ScreenCatcherService.startRecording("gif")
                }
            ]

            // Screenshotting/recording with the popout still open would capture
            // the popout itself, so every action closes it first and waits a
            // beat for the compositor to actually hide the surface.
            function runAfterClose(action) {
                popoutColumn.closePopout();
                closeDelay.pendingAction = action;
                closeDelay.restart();
            }

            Timer {
                id: closeDelay
                interval: 180
                property var pendingAction: null
                onTriggered: {
                    if (pendingAction)
                        pendingAction();
                    pendingAction = null;
                }
            }

            Component {
                id: actionRowComponent

                StyledRect {
                    width: parent.width
                    height: 40
                    radius: Theme.cornerRadius
                    color: rowMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: modelData.icon
                            color: Theme.surfaceText
                            size: Theme.iconSize - 4
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: popoutColumn.runAfterClose(modelData.action)
                    }
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingL

                Column {
                    id: leftColumn
                    width: (parent.width - divider.width - parent.spacing * 2) / 2
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        text: "Screenshot"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: popoutColumn.screenshotActions
                        delegate: actionRowComponent
                    }
                }

                Rectangle {
                    id: divider
                    width: 1
                    height: Math.max(leftColumn.implicitHeight, rightColumn.implicitHeight)
                    color: Theme.outline
                }

                Column {
                    id: rightColumn
                    width: (parent.width - divider.width - parent.spacing * 2) / 2
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        text: "Audio"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceVariantText
                    }

                    DankToggle {
                        text: "Microphone"
                        checked: ScreenCatcherService.micOn
                        onToggled: isChecked => ScreenCatcherService.setMicOn(isChecked)
                    }

                    DankToggle {
                        text: "System Audio"
                        checked: ScreenCatcherService.sysAudioOn
                        onToggled: isChecked => ScreenCatcherService.setSysAudioOn(isChecked)
                    }

                    StyledText {
                        width: parent.width
                        topPadding: Theme.spacingM
                        text: "Record"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceVariantText
                        visible: !ScreenCatcherService.isRecording
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: !ScreenCatcherService.isRecording

                        Repeater {
                            model: popoutColumn.recordActions
                            delegate: actionRowComponent
                        }
                    }

                    StyledRect {
                        width: parent.width
                        height: 44
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.error, stopRowMouse.containsMouse ? 0.24 : 0.16)
                        visible: ScreenCatcherService.isRecording

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "stop_circle"
                                color: Theme.error
                                size: Theme.iconSize - 2
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Stop Recording · " + ScreenCatcherService.elapsedLabel
                                color: Theme.error
                                font.weight: Font.Medium
                            }
                        }

                        MouseArea {
                            id: stopRowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ScreenCatcherService.stopRecording()
                        }
                    }
                }
            }
        }
    }
}
