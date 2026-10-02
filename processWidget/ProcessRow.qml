import QtQuick
import qs.Common
import qs.Widgets

// One process: what it is, what it uses, and the button that ends it. A click
// anywhere else on the row copies the PID.
//
// The button asks politely by default -- SIGTERM lets a program save and
// close, and it may refuse -- and right-clicking it forces the matter with
// SIGKILL, the same split processRunner makes between Enter and its menu.
// Either way the service re-checks the PID first; see ProcessWidgetService.kill.
Rectangle {
    id: row

    property var entry: null
    property int cpuWidth: 56
    property int memWidth: 44
    property int killWidth: 30
    readonly property bool killing: !!entry && ProcessWidgetService.killingPid === String(entry.pid)
    // The shell running this bar would be refused anyway; its button is off.
    readonly property bool isShell: ProcessWidgetService.isShellEntry(entry)

    implicitHeight: 44
    height: implicitHeight
    radius: Theme.cornerRadius
    color: rowMouse.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"

    MouseArea {
        id: rowMouse

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ProcessWidgetService.copyPid(row.entry)
    }

    Row {
        id: content

        anchors.fill: parent
        anchors.leftMargin: Theme.spacingS
        spacing: Theme.spacingS

        Column {
            width: content.width - row.cpuWidth - row.memWidth - row.killWidth - content.spacing * 3
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            StyledText {
                width: parent.width
                text: row.entry ? row.entry.display : ""
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                text: row.entry ? (row.killing ? "checking PID " + row.entry.pid + "…" : row.entry.user + " · " + row.entry.pid + " · " + row.entry.args) : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }

        // ps's %CPU is per core, so a busy multi-threaded process passes 100.
        StyledText {
            width: row.cpuWidth
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: row.entry ? row.entry.pcpu.toFixed(1) + "%" : ""
            font.pixelSize: Theme.fontSizeSmall
            font.features: ({
                    "tnum": 1
                })
            color: row.entry ? ProcessWidgetService.colorFor(row.entry.pcpu, Theme.surfaceText) : Theme.surfaceText
        }

        StyledText {
            width: row.memWidth
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: row.entry ? row.entry.pmem.toFixed(1) + "%" : ""
            font.pixelSize: Theme.fontSizeSmall
            font.features: ({
                    "tnum": 1
                })
            color: Theme.surfaceVariantText
        }

        DankActionButton {
            width: row.killWidth
            height: row.killWidth
            buttonSize: row.killWidth
            anchors.verticalCenter: parent.verticalCenter
            iconName: row.killing ? "hourglass_empty" : "close"
            iconSize: Theme.iconSize - 6
            iconColor: Theme.surfaceVariantText
            enabled: !ProcessWidgetService.killBusy && !row.isShell
            tooltipText: "End " + (row.entry ? row.entry.display : "") + " (SIGTERM) · right-click to force (SIGKILL)"
            onClicked: ProcessWidgetService.kill(row.entry, false)

            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: ProcessWidgetService.kill(row.entry, true)
            }
        }
    }
}
