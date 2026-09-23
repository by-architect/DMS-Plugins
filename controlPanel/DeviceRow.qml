import QtQuick
import qs.Common
import qs.Widgets

// One row in a device list (wifi network, bluetooth device, audio sink).
// `item` is a plain object: { key, label, meta, connected, icon, busy }.
Rectangle {
    id: root

    required property var item
    property bool isTopMatch: false

    signal activated

    width: parent ? parent.width : 0
    height: 40
    radius: Theme.cornerRadius / 2
    color: hover.hovered ? Theme.surfaceHover : "transparent"
    border.color: root.isTopMatch ? Theme.primary : "transparent"
    border.width: root.isTopMatch ? 1 : 0

    HoverHandler {
        id: hover
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }

    DankIcon {
        id: rowIcon

        name: root.item.icon || "devices"
        size: 16
        color: root.item.connected ? Theme.primary : Theme.surfaceVariantText
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
    }

    Column {
        anchors.left: rowIcon.right
        anchors.leftMargin: Theme.spacingS
        anchors.right: trailing.left
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        StyledText {
            width: parent.width
            text: root.item.label || ""
            font.pixelSize: Theme.fontSizeSmall
            font.weight: root.item.connected ? Font.Medium : Font.Normal
            color: Theme.surfaceText
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            text: root.item.busy ? "connecting…" : (root.item.meta || "")
            font.pixelSize: Theme.fontSizeSmall - 2
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
            visible: text.length > 0
        }
    }

    Row {
        id: trailing

        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingXS

        DankSpinner {
            visible: root.item.busy === true
            running: visible
            size: 14
            anchors.verticalCenter: parent.verticalCenter
        }

        DankIcon {
            visible: root.item.connected === true
            name: "check_circle"
            size: 14
            color: Theme.primary
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
