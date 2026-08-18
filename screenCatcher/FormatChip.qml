import QtQuick
import qs.Common
import qs.Widgets

// A small selectable pill for choosing a file format (png/jpeg, mp4/mkv/gif).
// Several sit in a Row together; caller sets width/height explicitly.
StyledRect {
    id: root

    property string chipKey: ""
    property string label: ""
    property bool selected: false

    signal activated

    radius: height / 2
    color: selected ? Theme.primary : (mouseArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh)
    border.color: selected ? Theme.primary : Theme.outline
    border.width: 1

    Row {
        anchors.centerIn: parent
        spacing: Theme.spacingXS

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.chipKey
            font.pixelSize: Theme.fontSizeSmall - 1
            font.weight: Font.Bold
            color: root.selected ? Theme.onPrimary : Theme.surfaceVariantText
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            font.pixelSize: Theme.fontSizeSmall
            font.weight: root.selected ? Font.Bold : Font.Normal
            color: root.selected ? Theme.onPrimary : Theme.surfaceText
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }
}
