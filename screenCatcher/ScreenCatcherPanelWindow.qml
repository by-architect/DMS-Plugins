import QtQuick
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
//
// Two-column layout uses plain Row/Column with explicit width formulas
// instead of QtQuick.Layouts — Layout.fillWidth on a Column nested inside a
// RowLayout was producing a badly off-center split (the Column's own
// implicit-width-from-children computation fights the Layout's fill
// assignment), so the split is computed directly here instead.
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

    // Closes the panel (which destroys this window, being LazyLoader-backed)
    // and hands the actual action off to ScreenCatcherService, which outlives
    // us and runs it after a short delay — see the comment there for why the
    // delay can't live in this window itself. Toggles (mic/system audio/etc.)
    // skip this and act inline instead, since they don't need the panel hidden.
    function runAction(action) {
        win.closeRequested();
        ScreenCatcherService.runAfterClose(action);
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

            // One letter per *kind* of capture, Shift for the whole screen:
            // s/S screenshot, t/T to text, r/R record, g/G GIF. Two letters
            // per kind (the old S/F and R/D pairs) meant remembering which
            // arbitrary second letter belonged to which action; the Shift
            // rule is the same for all four, so there is only one thing to
            // remember. Toggles and format chips ignore Shift — there is no
            // fullscreen/selected distinction for them to carry.
            Keys.onPressed: event => {
                const full = (event.modifiers & Qt.ShiftModifier) !== 0;
                switch (event.key) {
                case Qt.Key_S:
                    win.runAction(() => full ? ScreenCatcherService.takeScreenshotFullscreen() : ScreenCatcherService.takeScreenshotSelected());
                    break;
                case Qt.Key_T:
                    win.runAction(() => ScreenCatcherService.screenshotToText(full ? "full" : "select"));
                    break;
                case Qt.Key_C:
                    ScreenCatcherService.setCopyToClipboard(!ScreenCatcherService.copyToClipboard);
                    break;
                case Qt.Key_P:
                    ScreenCatcherService.setSaveToPictures(!ScreenCatcherService.saveToPictures);
                    break;
                case Qt.Key_N:
                    ScreenCatcherService.setNotifyOnComplete(!ScreenCatcherService.notifyOnComplete);
                    break;
                case Qt.Key_M:
                    ScreenCatcherService.setMicOn(!ScreenCatcherService.micOn);
                    break;
                case Qt.Key_Y:
                    ScreenCatcherService.setSysAudioOn(!ScreenCatcherService.sysAudioOn);
                    break;
                case Qt.Key_B:
                    ScreenCatcherService.setCopyVideoToClipboard(!ScreenCatcherService.copyVideoToClipboard);
                    break;
                case Qt.Key_V:
                    ScreenCatcherService.setSaveToVideos(!ScreenCatcherService.saveToVideos);
                    break;
                case Qt.Key_R:
                    if (!ScreenCatcherService.isRecording)
                        win.runAction(() => ScreenCatcherService.startRecording(full ? "full" : "select"));
                    break;
                case Qt.Key_G:
                    if (!ScreenCatcherService.isRecording)
                        win.runAction(() => ScreenCatcherService.recordGif(full ? "full" : "select"));
                    break;
                case Qt.Key_X:
                    if (ScreenCatcherService.isRecording || ScreenCatcherService.isSelecting)
                        ScreenCatcherService.stopRecording();
                    break;
                case Qt.Key_1:
                    if (!ScreenCatcherService.isRecording)
                        ScreenCatcherService.setImageFormat("png");
                    break;
                case Qt.Key_2:
                    if (!ScreenCatcherService.isRecording)
                        ScreenCatcherService.setImageFormat("jpeg");
                    break;
                case Qt.Key_3:
                    if (!ScreenCatcherService.isRecording)
                        ScreenCatcherService.setRecordFormat("mp4");
                    break;
                case Qt.Key_4:
                    if (!ScreenCatcherService.isRecording)
                        ScreenCatcherService.setRecordFormat("mkv");
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }

            // Centered card, half the window's width — and half its height
            // unless the columns need more. Giving each capture a Shift
            // variant added a row to both columns, which overflowed a flat
            // half-height card on a 1080p screen: the bottom toggle was
            // simply cut off. The height now grows to whatever the taller
            // column asks for, capped so the card always stays on screen.
            Rectangle {
                id: card

                readonly property real contentHeight: header.height + cardContent.spacing + Math.max(leftColumn.implicitHeight, rightColumn.implicitHeight) + Theme.spacingL * 2

                anchors.centerIn: parent
                width: win.width / 2
                height: Math.min(win.height - Theme.spacingL * 2, Math.max(win.height / 2, contentHeight))
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

                Column {
                    id: cardContent
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Item {
                        id: header
                        width: parent.width
                        height: 40

                        DankIcon {
                            id: headerIcon
                            name: "screenshot_monitor"
                            size: 26
                            color: Theme.primary
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            anchors.left: headerIcon.right
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: closeButton.left
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            StyledText {
                                text: "Screen Catcher"
                                font.pixelSize: Theme.fontSizeLarge + 2
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                text: ScreenCatcherService.isRecording ? ("Recording " + ScreenCatcherService.recordingLabel + " · " + ScreenCatcherService.elapsedLabel + " — X stops") : (ScreenCatcherService.isSelecting ? "Starting a recording — X cancels" : "Press a letter for the selection, Shift for the whole screen — Esc closes")
                                font.pixelSize: Theme.fontSizeSmall
                                color: (ScreenCatcherService.isRecording || ScreenCatcherService.isSelecting) ? Theme.error : Theme.surfaceVariantText
                            }
                        }

                        DankActionButton {
                            id: closeButton
                            iconName: "close"
                            iconSize: 20
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: win.closeRequested()
                        }
                    }

                    Row {
                        id: columns
                        width: parent.width
                        height: parent.height - header.height - parent.spacing
                        spacing: Theme.spacingL

                        Column {
                            id: leftColumn
                            width: (columns.width - divider.width - columns.spacing * 2) / 2
                            height: parent.height
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
                                letter: "⇧S"
                                icon: "fullscreen"
                                label: "Screenshot Fullscreen"
                                onActivated: win.runAction(() => ScreenCatcherService.takeScreenshotFullscreen())
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                letter: "T"
                                icon: "text_fields"
                                label: "Selection to Text"
                                onActivated: win.runAction(() => ScreenCatcherService.screenshotToText("select"))
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                letter: "⇧T"
                                icon: "text_fields"
                                label: "Fullscreen to Text"
                                onActivated: win.runAction(() => ScreenCatcherService.screenshotToText("full"))
                            }

                            Row {
                                width: parent.width
                                height: 28
                                spacing: Theme.spacingXS

                                FormatChip {
                                    width: (parent.width - parent.spacing) / 2
                                    height: parent.height
                                    chipKey: "1"
                                    label: "PNG"
                                    selected: ScreenCatcherService.imageFormat === "png"
                                    onActivated: ScreenCatcherService.setImageFormat("png")
                                }

                                FormatChip {
                                    width: (parent.width - parent.spacing) / 2
                                    height: parent.height
                                    chipKey: "2"
                                    label: "JPEG"
                                    selected: ScreenCatcherService.imageFormat === "jpeg"
                                    onActivated: ScreenCatcherService.setImageFormat("jpeg")
                                }
                            }

                            StyledText {
                                width: parent.width
                                topPadding: Theme.spacingM
                                text: "Save screenshots"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                color: Theme.surfaceVariantText
                            }

                            ToggleRow {
                                width: parent.width
                                height: 32
                                letter: "C"
                                label: "Save to Clipboard"
                                checked: ScreenCatcherService.copyToClipboard
                                onActivated: ScreenCatcherService.setCopyToClipboard(!ScreenCatcherService.copyToClipboard)
                            }

                            ToggleRow {
                                width: parent.width
                                height: 32
                                letter: "P"
                                label: "Save to Pictures"
                                checked: ScreenCatcherService.saveToPictures
                                onActivated: ScreenCatcherService.setSaveToPictures(!ScreenCatcherService.saveToPictures)
                            }

                            ToggleRow {
                                width: parent.width
                                height: 32
                                letter: "N"
                                label: "Notifications"
                                checked: ScreenCatcherService.notifyOnComplete
                                onActivated: ScreenCatcherService.setNotifyOnComplete(!ScreenCatcherService.notifyOnComplete)
                            }
                        }

                        Rectangle {
                            id: divider
                            width: 1
                            height: parent.height
                            color: Theme.outline
                        }

                        Column {
                            id: rightColumn
                            width: (columns.width - divider.width - columns.spacing * 2) / 2
                            height: parent.height
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
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting
                                letter: "R"
                                icon: "crop_free"
                                label: "Record Selected"
                                onActivated: win.runAction(() => ScreenCatcherService.startRecording("select"))
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting
                                letter: "⇧R"
                                icon: "screen_record"
                                label: "Record Fullscreen"
                                onActivated: win.runAction(() => ScreenCatcherService.startRecording("full"))
                            }

                            // Its own action rather than a third format chip:
                            // a GIF chip left selected turns the next ordinary
                            // recording into a GIF by surprise.
                            ActionRow {
                                width: parent.width
                                height: 40
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting
                                letter: "G"
                                icon: "gif_box"
                                label: "Record Selected as GIF"
                                onActivated: win.runAction(() => ScreenCatcherService.recordGif("select"))
                            }

                            ActionRow {
                                width: parent.width
                                height: 40
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting
                                letter: "⇧G"
                                icon: "gif_box"
                                label: "Record Fullscreen as GIF"
                                onActivated: win.runAction(() => ScreenCatcherService.recordGif("full"))
                            }

                            Row {
                                width: parent.width
                                height: 28
                                spacing: Theme.spacingXS
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting

                                FormatChip {
                                    width: (parent.width - parent.spacing) / 2
                                    height: parent.height
                                    chipKey: "3"
                                    label: "MP4"
                                    selected: ScreenCatcherService.recordFormat === "mp4"
                                    onActivated: ScreenCatcherService.setRecordFormat("mp4")
                                }

                                FormatChip {
                                    width: (parent.width - parent.spacing) / 2
                                    height: parent.height
                                    chipKey: "4"
                                    label: "MKV"
                                    selected: ScreenCatcherService.recordFormat === "mkv"
                                    onActivated: ScreenCatcherService.setRecordFormat("mkv")
                                }
                            }

                            StyledText {
                                width: parent.width
                                topPadding: Theme.spacingM
                                text: "Save recordings"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                color: Theme.surfaceVariantText
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting
                            }

                            ToggleRow {
                                width: parent.width
                                height: 32
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting
                                letter: "B"
                                label: "Save to Clipboard"
                                checked: ScreenCatcherService.copyVideoToClipboard
                                onActivated: ScreenCatcherService.setCopyVideoToClipboard(!ScreenCatcherService.copyVideoToClipboard)
                            }

                            ToggleRow {
                                width: parent.width
                                height: 32
                                visible: !ScreenCatcherService.isRecording && !ScreenCatcherService.isSelecting
                                letter: "V"
                                label: "Save to Videos"
                                checked: ScreenCatcherService.saveToVideos
                                onActivated: ScreenCatcherService.setSaveToVideos(!ScreenCatcherService.saveToVideos)
                            }

                            // Visible during the selection/startup phase as well,
                            // so a recording that is waiting on slurp can always be
                            // called off from the panel it was started from.
                            ActionRow {
                                width: parent.width
                                height: 44
                                visible: ScreenCatcherService.isRecording || ScreenCatcherService.isSelecting
                                danger: true
                                letter: "X"
                                icon: "stop_circle"
                                label: ScreenCatcherService.isRecording ? ("Stop Recording · " + ScreenCatcherService.elapsedLabel) : "Cancel Recording"
                                onActivated: ScreenCatcherService.stopRecording()
                            }
                        }
                    }
                }
            }
        }
    }
}
