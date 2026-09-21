import QtQuick
import qs.Common
import qs.Widgets

// The line between what you had seen and what you had not.
//
// Drawn where the conversation was when it was opened, and kept there while it
// is open even though opening marks it read: the point of the mark is to say
// "you got to here", and it would be useless if it moved as you read.
Item {
    id: root

    implicitHeight: label.implicitHeight + Theme.spacingS * 2
    height: implicitHeight

    Rectangle {
        anchors.left: parent.left
        anchors.right: label.left
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        color: Theme.primary
        opacity: 0.4
    }

    StyledText {
        id: label
        anchors.centerIn: parent
        text: I18n.tr("New messages")
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.primary
    }

    Rectangle {
        anchors.left: label.right
        anchors.leftMargin: Theme.spacingS
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        color: Theme.primary
        opacity: 0.4
    }
}
