import QtQuick
import qs.Common
import qs.Widgets
import "view.js" as View

// One task: its circle, its title (struck through once done) with its notes
// under it, and on the right whether it is still on its way to the server,
// how old it is, and a delete button that shows on hover.
Rectangle {
    id: row

    // A row from view.js rows(); null for a moment while the list catches up.
    property var task: null
    property bool selected: false
    property real nowMs: 0

    signal selectRequested
    signal toggleRequested
    signal deleteRequested

    readonly property bool done: !!task && task.completed === true
    readonly property string failed: task && task.failed ? task.failed : ""

    height: Math.max(36, body.implicitHeight + Theme.spacingS * 2)
    radius: Theme.cornerRadius
    color: selected ? Theme.withAlpha(Theme.primary, 0.14) : hover.hovered ? Theme.surfaceHover : "transparent"
    border.color: selected ? Theme.primary : "transparent"
    border.width: selected ? 1 : 0

    HoverHandler {
        id: hover
    }

    MouseArea {
        anchors.fill: parent
        onClicked: row.selectRequested()
    }

    Item {
        id: check

        x: Theme.spacingS + (row.task ? row.task.depth || 0 : 0) * 22
        y: (36 - height) / 2
        width: 24
        height: 24

        DankIcon {
            anchors.centerIn: parent
            name: row.done ? "check_circle" : "radio_button_unchecked"
            size: 20
            color: row.done ? Theme.primary : Theme.surfaceVariantText
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: row.toggleRequested()
        }
    }

    Column {
        id: body

        anchors.left: check.right
        anchors.leftMargin: Theme.spacingS
        anchors.right: trailing.left
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        StyledText {
            width: parent.width
            text: row.task ? row.task.summary || "(untitled)" : ""
            wrapMode: Text.Wrap
            font.pixelSize: Theme.fontSizeMedium
            font.strikeout: row.done
            color: row.done ? Theme.surfaceVariantText : Theme.surfaceText
        }

        // Two lines of notes, all of them when selected.
        StyledText {
            width: parent.width
            visible: text !== ""
            text: row.task ? row.task.description || "" : ""
            wrapMode: Text.Wrap
            maximumLineCount: row.selected ? 40 : 2
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            width: parent.width
            visible: row.failed !== ""
            text: row.failed + " — Ctrl+R tries again"
            wrapMode: Text.Wrap
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.error
        }
    }

    Row {
        id: trailing

        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingXS
        anchors.top: parent.top
        anchors.topMargin: (36 - height) / 2
        spacing: Theme.spacingXS

        DankIcon {
            visible: !!row.task && row.task.pending && row.failed === ""
            name: "cloud_upload"
            size: 14
            color: Theme.surfaceVariantText
            anchors.verticalCenter: parent.verticalCenter
        }

        DankIcon {
            visible: row.failed !== ""
            name: "error"
            size: 14
            color: Theme.error
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            text: row.task ? View.age(row.done && row.task.completedAt ? row.task.completedAt : row.task.created, row.nowMs) : ""
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            anchors.verticalCenter: parent.verticalCenter
        }

        DankActionButton {
            iconName: "close"
            iconSize: 16
            opacity: hover.hovered || row.selected ? 1 : 0
            enabled: opacity > 0
            anchors.verticalCenter: parent.verticalCenter
            onClicked: row.deleteRequested()
        }
    }
}
