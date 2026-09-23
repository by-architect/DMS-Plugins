import QtQuick
import qs.Common
import qs.Widgets

// One on/off row in the Other container: icon, label, optional meta line,
// toggle. `letter` is optional — VPN profiles (a variable-length list) don't
// get a reserved hotkey the way the singular Mic/Tailscale/Keep Awake do.
Rectangle {
    id: root

    property string iconName: "toggle_on"
    property string label: ""
    property string meta: ""
    property string letter: ""
    property bool checked: false
    property bool enabled: true

    signal toggled

    width: parent ? parent.width : 0
    height: 40
    radius: Theme.cornerRadius / 2
    color: hover.hovered ? Theme.surfaceHover : "transparent"
    opacity: enabled ? 1 : 0.5

    HoverHandler {
        id: hover
        enabled: root.enabled
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
    }

    DankIcon {
        id: rowIcon

        name: root.iconName
        size: 16
        color: root.checked ? Theme.primary : Theme.surfaceVariantText
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
            text: root.label
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            text: root.meta
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
        spacing: Theme.spacingS

        LetterBadge {
            letter: root.letter
            active: root.checked
            visible: root.letter.length > 0
            anchors.verticalCenter: parent.verticalCenter
        }

        DankToggle {
            checked: root.checked
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.toggled()
        }
    }
}
