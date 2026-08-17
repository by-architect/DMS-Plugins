import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Widgets
import "util.js" as Util

// The fullscreen surface itself.
//
// This must be instantiated by a LazyLoader (or createObject), never declared
// inline inside the PluginComponent: a PanelWindow parented to the plugin's
// Item never reifies as a layer surface.
PanelWindow {
    id: win

    property int journalDays: 30
    property bool autoRefresh: true

    // Exposed over IPC so keyboard reachability can be checked without guessing:
    // if this is false, Esc will not reach the panel.
    readonly property bool keyboardReady: rootFocus.activeFocus

    signal closeRequested

    visible: true
    color: "transparent"

    WlrLayershell.namespace: "dms:system-panel"
    WlrLayershell.layer: WlrLayer.Overlay

    // Hyprland ignores exclusive layer-shell keyboard focus in the shell's
    // default configuration and uses hyprland_focus_grab instead, so mirror the
    // shell's own policy rather than hardcoding Exclusive (which silently leaves
    // the panel unable to receive Esc).
    WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(true, null)

    DankFocusGrab {
        windows: [win]
        wanted: KeyboardFocus.wantsGrab(true, null)
    }

    // Fill the usable screen but respect the bar's exclusive zone, otherwise the
    // panel header renders underneath the bar.
    exclusionMode: ExclusionMode.Normal
    WlrLayershell.exclusiveZone: 0

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    SystemData {
        id: sysData

        journalDays: win.journalDays
    }

    Component.onCompleted: {
        sysData.refreshAll();
        rootFocus.forceActiveFocus();
    }

    Timer {
        interval: 30000
        repeat: true
        running: win.autoRefresh
        onTriggered: sysData.refreshAll()
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha(Theme.background, 0.985)

        FocusScope {
            id: rootFocus

            anchors.fill: parent
            focus: true

            Keys.onEscapePressed: win.closeRequested()
            Keys.onPressed: event => {
                if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                    sysData.refreshAll();
                    event.accepted = true;
                } else if (event.key === Qt.Key_F5) {
                    sysData.refreshAll();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Q) {
                    win.closeRequested();
                    event.accepted = true;
                }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                // ------------------------------------------------------ header
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44

                    DankIcon {
                        id: headerIcon

                        name: "monitor_heart"
                        size: 26
                        color: Theme.primary
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        anchors.left: headerIcon.right
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        StyledText {
                            text: "System Panel"
                            font.pixelSize: Theme.fontSizeLarge + 2
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: {
                                const info = sysData.overviewData;
                                if (!info)
                                    return "collecting…";
                                return info.host + "  ·  " + info.os + "  ·  up " + Util.fmtDuration(info.uptimeSeconds);
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingM

                        StyledText {
                            text: sysData.busy ? "refreshing…" : "Esc close  ·  Ctrl+R refresh"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            opacity: 0.8
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        DankActionButton {
                            iconName: "refresh"
                            iconSize: 20
                            enabled: !sysData.busy
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: sysData.refreshAll()
                        }

                        DankActionButton {
                            iconName: "close"
                            iconSize: 20
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: win.closeRequested()
                        }
                    }
                }

                // -------------------------------------------------- 3x3 grid
                GridLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    columns: 3
                    rows: 3
                    columnSpacing: Theme.spacingM
                    rowSpacing: Theme.spacingM

                    LoginHistoryTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    InboundSshTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    TailscaleTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    BootHealthTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    SessionsTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    SudoTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    OverviewTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    UnitsTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    PortsTile {
                        data: sysData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
                }
            }
        }
    }
}
