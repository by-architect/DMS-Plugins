import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Widgets

// The panel surface itself.
//
// This must be instantiated by a LazyLoader (or createObject), never declared
// inline inside the PluginComponent: a PanelWindow parented to the plugin's
// Item never reifies as a layer surface (see ScreenCatcherDaemon.qml).
//
// The layer surface itself is fullscreen (needed to dim the background and
// catch Esc/letter keys anywhere), but the actual card is centered and sized
// to half the window's width/height — that's the "panel" the user asked for.
PanelWindow {
    id: win

    signal closeRequested

    // Exposed for `screenCatcher status` over IPC, so keyboard reachability
    // can be checked without guessing.
    readonly property bool keyboardReady: rootFocus.activeFocus

    visible: true
    color: "transparent"

    WlrLayershell.namespace: "dms:screen-catcher"
    WlrLayershell.layer: WlrLayer.Overlay

    // Hyprland ignores exclusive layer-shell keyboard focus in the shell's
    // default configuration and uses hyprland_focus_grab instead, so mirror the
    // shell's own policy rather than hardcoding Exclusive (which silently leaves
    // the panel unable to receive Esc/letter keys).
    WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(true, null)

    DankFocusGrab {
        windows: [win]
        wanted: KeyboardFocus.wantsGrab(true, null)
    }

    exclusionMode: ExclusionMode.Normal
    WlrLayershell.exclusiveZone: 0

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // Every action closes the panel first and waits a beat for the compositor
    // to actually hide the surface, so screenshots/recordings never capture
    // the panel itself. Toggles (mic/system audio) skip this and act inline.
    function runAction(action) {
        win.closeRequested();
        actionDelay.pendingAction = action;
        actionDelay.restart();
    }

    Timer {
        id: actionDelay
        interval: 180
        property var pendingAction: null
        onTriggered: {
            if (pendingAction)
                pendingAction();
            pendingAction = null;
        }
    }

    Component.onCompleted: rootFocus.forceActiveFocus()

    Rectangle {
        id: backdrop
        anchors.fill: parent
        color: Theme.withAlpha(Theme.background, 0.6)

        MouseArea {
            anchors.fill: parent
            onClicked: win.closeRequested()
        }

        FocusScope {
            id: rootFocus
            anchors.fill: parent
            focus: true

            Keys.onEscapePressed: win.closeRequested()
            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_S:
                    win.runAction(() => ScreenCatcherService.takeScreenshotSelected());
                    break;
                case Qt.Key_F:
                    win.runAction(() => ScreenCatcherService.takeScreenshotFullscreen());
                    break;
                case Qt.Key_T:
                    win.runAction(() => ScreenCatcherService.screenshotToText());
                    break;
                case Qt.Key_M:
                    ScreenCatcherService.setMicOn(!ScreenCatcherService.micOn);
                    break;
                case Qt.Key_Y:
                    ScreenCatcherService.setSysAudioOn(!ScreenCatcherService.sysAudioOn);
                    break;
                case Qt.Key_R:
                    if (!ScreenCatcherService.isRecording)
                        win.runAction(() => ScreenCatcherService.startRecording("full"));
                    break;
                case Qt.Key_D:
                    if (!ScreenCatcherService.isRecording)
                        win.runAction(() => ScreenCatcherService.startRecording("select"));
                    break;
                case Qt.Key_G:
                    if (!ScreenCatcherService.isRecording)
                        win.runAction(() => ScreenCatcherService.startRecording("gif"));
                    break;
                case Qt.Key_X:
                    if (ScreenCatcherService.isRecording)
                        ScreenCatcherService.stopRecording();
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }

            // Centered card, half the window's width/height.
            Rectangle {
                id: card
                anchors.centerIn: parent
                width: win.width / 2
                height: win.height / 2
                radius: Theme.cornerRadius * 1.5
                color: Theme.surfaceContainer
                border.color: Theme.outline
                border.width: 1

                // Swallows clicks on the card so they don't fall through to
                // the backdrop's click-outside-to-close handler.
                MouseArea {
                    anchors.fill: parent
                    onClicked: mouse => mouse.accepted = true
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingM

                        DankIcon {
                            name: "screenshot_monitor"
                            size: 26
                            color: Theme.primary
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            StyledText {
                                text: "Screen Catcher"
                                font.pixelSize: Theme.fontSizeLarge + 2
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                text: ScreenCatcherService.isRecording ? ("Recording " + ScreenCatcherService.recordingLabel + " · " + ScreenCatcherService.elapsedLabel + " — press X to stop") : "Press a letter, or click — Esc closes"
                                font.pixelSize: Theme.fontSizeSmall
                                color: ScreenCatcherService.isRecording ? Theme.error : Theme.surfaceVariantText
                            }
                        }

                        DankActionButton {
                            iconName: "close"
                            iconSize: 20
                            onClicked: win.closeRequested()
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: Theme.spacingL

                        Column {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: Theme.spacingS

                            StyledText {
                                width: parent.width
                                text: "Screenshot"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                color: Theme.surfaceVariantText
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                letter: "S"
                                icon: "crop"
                                label: "Screenshot Selected"
                                onActivated: win.runAction(() => ScreenCatcherService.takeScreenshotSelected())
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                letter: "F"
                                icon: "fullscreen"
                                label: "Screenshot Fullscreen"
                                onActivated: win.runAction(() => ScreenCatcherService.takeScreenshotFullscreen())
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                letter: "T"
                                icon: "text_fields"
                                label: "Screenshot to Text"
                                onActivated: win.runAction(() => ScreenCatcherService.screenshotToText())
                            }
                        }

                        Rectangle {
                            Layout.preferredWidth: 1
                            Layout.fillHeight: true
                            color: Theme.outline
                        }

                        Column {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: Theme.spacingS

                            StyledText {
                                width: parent.width
                                text: "Audio"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                color: Theme.surfaceVariantText
                            }

                            ToggleRow {
                                width: parent.width
                                height: 32
                                letter: "M"
                                label: "Microphone"
                                checked: ScreenCatcherService.micOn
                                onActivated: ScreenCatcherService.setMicOn(!ScreenCatcherService.micOn)
                            }

                            ToggleRow {
                                width: parent.width
                                height: 32
                                letter: "Y"
                                label: "System Audio"
                                checked: ScreenCatcherService.sysAudioOn
                                onActivated: ScreenCatcherService.setSysAudioOn(!ScreenCatcherService.sysAudioOn)
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

                            ActionRow {
                                width: parent.width
                                height: 40
                                visible: !ScreenCatcherService.isRecording
                                letter: "R"
                                icon: "screen_record"
                                label: "Record Fullscreen"
                                onActivated: win.runAction(() => ScreenCatcherService.startRecording("full"))
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                visible: !ScreenCatcherService.isRecording
                                letter: "D"
                                icon: "crop_free"
                                label: "Record Selected"
                                onActivated: win.runAction(() => ScreenCatcherService.startRecording("select"))
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                visible: !ScreenCatcherService.isRecording
                                letter: "G"
                                icon: "gif_box"
                                label: "Record Selected as GIF"
                                onActivated: win.runAction(() => ScreenCatcherService.startRecording("gif"))
                            }

                            ActionRow {
                                width: parent.width
                                height: 44
                                visible: ScreenCatcherService.isRecording
                                danger: true
                                letter: "X"
                                icon: "stop_circle"
                                label: "Stop Recording · " + ScreenCatcherService.elapsedLabel
                                onActivated: ScreenCatcherService.stopRecording()
                            }
                        }
                    }
                }
            }
        }
    }
}
