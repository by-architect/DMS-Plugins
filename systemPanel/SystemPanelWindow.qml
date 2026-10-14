import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Widgets
import "matrix.js" as Matrix
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
    // 0 this machine, 1 every machine through `matrix log`.
    property int page: 0
    // On the matrix page: "" for every machine, else one host's name.
    property string hostFilter: ""

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

    // True fullscreen: draw over the bar rather than reserving space below it.
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.exclusiveZone: -1

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

    FileActionsData {
        id: fileData
    }

    MatrixData {
        id: matrixData
    }

    function refreshPage() {
        if (win.page === 1) {
            matrixData.refreshAll();
            return;
        }
        sysData.refreshAll();
        fileData.refresh();
        fileData.refreshHistory();
    }

    // The matrix page reaches every machine over ssh, so it is only read once
    // it is looked at, not every time the panel opens.
    onPageChanged: {
        if (page === 1 && !matrixData.everRan && !matrixData.busy)
            matrixData.refreshAll();
    }

    Component.onCompleted: {
        sysData.refreshAll();
        if (page === 1)
            matrixData.refreshAll();
        rootFocus.forceActiveFocus();
    }

    Timer {
        interval: 30000
        repeat: true
        running: win.autoRefresh
        onTriggered: sysData.refreshAll()
    }

    // Slower than the local tiles: every run is an ssh to every machine.
    Timer {
        interval: 120000
        repeat: true
        running: win.autoRefresh && win.page === 1
        onTriggered: matrixData.refreshAll()
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
                    win.refreshPage();
                    event.accepted = true;
                } else if (event.key === Qt.Key_F5) {
                    win.refreshPage();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                    win.page = win.page === 0 ? 1 : 0;
                    event.accepted = true;
                } else if (event.key === Qt.Key_1) {
                    win.page = 0;
                    event.accepted = true;
                } else if (event.key === Qt.Key_2) {
                    win.page = 1;
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

                    // The two pages; Tab, 1 and 2 switch between them too.
                    DankFilterChips {
                        anchors.centerIn: parent
                        width: singleRowWidth
                        showCheck: false
                        showCounts: false
                        model: [
                            {
                                label: "This machine",
                                value: "local"
                            },
                            {
                                label: "All machines · matrix",
                                value: "matrix"
                            }
                        ]
                        currentIndex: win.page
                        onSelectionChanged: index => win.page = index
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingM

                        StyledText {
                            readonly property bool busy: win.page === 1 ? matrixData.busy : sysData.busy
                            text: busy ? "refreshing…" : "Tab page  ·  Esc close  ·  Ctrl+R refresh"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            opacity: 0.8
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        DankActionButton {
                            iconName: "refresh"
                            iconSize: 20
                            enabled: win.page === 1 ? !matrixData.busy : !sysData.busy
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: win.refreshPage()
                        }

                        DankActionButton {
                            iconName: "close"
                            iconSize: 20
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: win.closeRequested()
                        }
                    }
                }

                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: win.page

                    // ------------------------------------- this machine: 3x3 grid
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

                        SystemErrorsTile {
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

                        FileActionsTile {
                            data: fileData
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

                    // ------------------------- all machines: one tile per kind
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: Theme.spacingM

                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.max(hostChips.height, matrixState.implicitHeight)

                            // Which machine the tiles show; every one by default.
                            DankFilterChips {
                                id: hostChips

                                readonly property var hostList: matrixData.hosts

                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - matrixState.implicitWidth - Theme.spacingL
                                showCheck: false
                                showCounts: false
                                model: [
                                    {
                                        label: "All machines",
                                        value: ""
                                    }
                                ].concat(hostList.map(h => ({
                                            label: matrixData.unreachable.indexOf(h) >= 0 ? h + " (unreachable)" : h,
                                            value: h
                                        })))
                                currentIndex: win.hostFilter ? Math.max(0, hostList.indexOf(win.hostFilter) + 1) : 0
                                onSelectionChanged: index => win.hostFilter = index > 0 ? hostList[index - 1] : ""
                            }

                            StyledText {
                                id: matrixState

                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: matrixData.busy ? "reading matrix log on every machine…" : "matrix log --json · every 2 minutes while open"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                opacity: 0.8
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            columns: 4
                            rows: 2
                            uniformCellWidths: true
                            uniformCellHeights: true
                            columnSpacing: Theme.spacingM
                            rowSpacing: Theme.spacingM

                            Repeater {
                                model: Matrix.KINDS

                                MatrixLogTile {
                                    required property var modelData

                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    info: modelData
                                    result: matrixData.results[modelData.kind] ?? null
                                    hostFilter: win.hostFilter
                                    limit: matrixData.limit
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
