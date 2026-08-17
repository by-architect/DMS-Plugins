import QtQuick
import qs.Common
import qs.Widgets

// A single list entry inside a tile: status dot, two lines of text on the left,
// and a right-aligned trailing column (usually a relative timestamp).
Rectangle {
    id: root

    property string primary: ""
    property string secondary: ""
    property string trailing: ""
    property string trailingSub: ""
    property color dotColor: Theme.surfaceVariantText
    property color primaryColor: Theme.surfaceText
    property bool showDot: true
    property string iconName: ""

    width: parent ? parent.width : 0
    height: Math.max(34, textColumn.implicitHeight + Theme.spacingS)
    color: hover.hovered ? Theme.surfaceHover : "transparent"
    radius: Theme.cornerRadius / 2

    HoverHandler {
        id: hover
    }

    Rectangle {
        id: dot

        width: 7
        height: 7
        radius: 3.5
        color: root.dotColor
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingXS
        anchors.top: parent.top
        anchors.topMargin: 12
        visible: root.showDot && !root.iconName
    }

    DankIcon {
        id: rowIcon

        name: root.iconName
        size: 14
        color: root.dotColor
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingXS - 3
        anchors.top: parent.top
        anchors.topMargin: 9
        visible: root.iconName.length > 0
    }

    Column {
        id: textColumn

        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingXS + 14
        anchors.right: trailingColumn.left
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1

        StyledText {
            width: parent.width
            text: root.primary
            font.pixelSize: Theme.fontSizeSmall
            color: root.primaryColor
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            text: root.secondary
            font.pixelSize: Theme.fontSizeSmall - 2
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
            visible: text.length > 0
        }
    }

    Column {
        id: trailingColumn

        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1
        width: Math.max(trailingText.implicitWidth, trailingSubText.implicitWidth)

        StyledText {
            id: trailingText

            anchors.right: parent.right
            text: root.trailing
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }

        StyledText {
            id: trailingSubText

            anchors.right: parent.right
            text: root.trailingSub
            font.pixelSize: Theme.fontSizeSmall - 2
            color: Theme.surfaceVariantText
            opacity: 0.7
            visible: text.length > 0
        }
    }
}
