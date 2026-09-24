import QtQuick
import qs.Common
import "actions.js" as Actions

// File operations in progress plus their recent history, ported from the
// fileActions plugin's live + journal model (see FileActionsData.qml).
PanelTile {
    id: root

    required property var data

    readonly property var activeList: data.active || []
    readonly property var historyList: data.history || []

    title: "File Actions"
    iconName: "sync_alt"
    busy: !data.everPolled
    empty: data.everPolled && activeList.length === 0 && historyList.length === 0
    emptyText: data.dirPresent ? "No file operations seen yet" : "No matrix fct/dejavu watch directory found"
    statusText: activeList.length > 0 ? (activeList.length + " running") : "idle"
    statusColor: activeList.length > 0 ? Theme.warning : Theme.surfaceVariantText
    footerText: "cp / mv / rsync / trash — live + history"

    Repeater {
        model: root.activeList

        TileRow {
            required property var modelData

            primary: Actions.titleOf(modelData) + (modelData.paused ? "  ·  paused" : "")
            secondary: Actions.subtitleOf(modelData)
            trailing: modelData.percent >= 0 ? Actions.percentText(modelData.percent) : "running"
            trailingSub: modelData.stale ? "stalled" : ""
            dotColor: modelData.stale ? Theme.error : Theme.warning
            iconName: Actions.iconFor(modelData.command)
        }
    }

    Item {
        width: parent ? parent.width : 0
        height: recentLabel.visible ? recentLabel.implicitHeight + 4 : 0

        StyledText {
            id: recentLabel

            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingXS + 14
            anchors.top: parent.top
            anchors.topMargin: 4
            text: "Recent"
            font.pixelSize: Theme.fontSizeSmall - 2
            color: Theme.surfaceVariantText
            opacity: 0.6
            visible: root.activeList.length > 0 && root.historyList.length > 0
        }
    }

    Repeater {
        model: root.historyList

        TileRow {
            required property var modelData

            primary: Actions.titleOf(modelData)
            secondary: Actions.doneSubtitleOf(modelData)
            trailing: Actions.relTime(modelData.endedMs, Date.now())
            trailingSub: modelData.phase === "failed" ? "failed" : ""
            dotColor: modelData.phase === "failed" ? Theme.error : Theme.success
            primaryColor: modelData.phase === "failed" ? Theme.error : Theme.surfaceText
            iconName: Actions.iconFor(modelData.command)
        }
    }
}
