import QtQuick
import qs.Common
import qs.Widgets

// Same letter-keycap treatment as ActionRow, but for an on/off setting. The
// whole row is clickable; the DankToggle track is layered on top so its own
// hit area still wins over the row-wide MouseArea beneath it.
Item {
    id: root

    property string letter: ""
    property string label: ""
    property bool checked: false

    signal activated

    MouseArea {
        id: rowArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }

    Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        Rectangle {
            width: 20
            height: 20
            radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.withAlpha(Theme.primary, 0.16)
            border.color: Theme.primary
            border.width: 1

            StyledText {
                anchors.centerIn: parent
                text: root.letter
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
                color: Theme.primary
            }
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    DankToggle {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: root.checked
        onToggled: () => root.activated()
    }
}
