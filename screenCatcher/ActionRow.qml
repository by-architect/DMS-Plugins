import QtQuick
import qs.Common
import qs.Widgets

// A clickable row with a visible letter "keycap" badge, so the panel's
// letter-mnemonic keyboard shortcuts are discoverable, not just documented.
// Caller sets width/height explicitly (used inside a plain Column).
StyledRect {
    id: root

    property string letter: ""
    property string icon: ""
    property string label: ""
    property bool danger: false
    // Rows that are showing state rather than offering an action (the
    // "Saving…" row while a recording finalizes) set this: no hover, no
    // pointer cursor, no click.
    property bool interactive: true

    signal activated

    radius: Theme.cornerRadius
    opacity: interactive ? 1 : 0.7
    color: danger ? Theme.withAlpha(Theme.error, (mouseArea.containsMouse && interactive) ? 0.24 : 0.16) : ((mouseArea.containsMouse && interactive) ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh)

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        Rectangle {
            width: 20
            height: 20
            radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.withAlpha(root.danger ? Theme.error : Theme.primary, 0.16)
            border.color: root.danger ? Theme.error : Theme.primary
            border.width: 1

            StyledText {
                anchors.centerIn: parent
                text: root.letter
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
                color: root.danger ? Theme.error : Theme.primary
            }
        }

        DankIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: root.icon
            color: root.danger ? Theme.error : Theme.surfaceText
            size: Theme.iconSize - 4
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: root.danger ? Theme.error : Theme.surfaceText
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        enabled: root.interactive
        hoverEnabled: root.interactive
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }
}
