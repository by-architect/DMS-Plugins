pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

// Who can be mentioned, for "@" typed in the composer: a short list over the
// field, best match first. The composer owns the keys -- the field keeps the
// keyboard, so typing goes on narrowing the list -- and this only draws it and
// takes a click.
StyledRect {
    id: root

    // Who to offer: { id, name, avatarPath }, best first.
    property var people: []
    // The row the keyboard is on.
    property int highlighted: 0

    signal picked(int index)

    readonly property int rowHeight: 40

    height: list.contentHeight + Theme.spacingXS * 2
    radius: Theme.cornerRadius
    color: Theme.surfaceContainerHigh
    border.color: Theme.withAlpha(Theme.outline, 0.3)
    border.width: 1

    // Clicks between the rows stay here rather than reaching the messages.
    MouseArea {
        anchors.fill: parent
    }

    ListView {
        id: list
        anchors.fill: parent
        anchors.margins: Theme.spacingXS
        interactive: false
        model: root.people
        spacing: 0

        delegate: StyledRect {
            id: row

            required property var modelData
            required property int index

            readonly property bool isHighlighted: row.index === root.highlighted

            width: ListView.view.width
            height: root.rowHeight
            radius: Theme.cornerRadius / 2
            color: row.isHighlighted ? Theme.primarySelected : (rowArea.containsMouse ? Theme.surfaceHover : "transparent")

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picked(row.index)
            }

            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingS
                anchors.rightMargin: Theme.spacingS
                spacing: Theme.spacingS

                DankCircularImage {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 26
                    height: 26
                    imageSource: (row.modelData.avatarPath || "") !== "" ? "file://" + row.modelData.avatarPath : ""
                    fallbackText: (row.modelData.name || "?").charAt(0).toUpperCase()
                    fallbackIcon: "person"
                }

                StyledText {
                    id: nameLabel
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - 26 - parent.spacing * 2 - Math.min(idLabel.implicitWidth, parent.width * 0.4))
                    text: row.modelData.name || row.modelData.id
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                // The address too, since two people can share a name.
                StyledText {
                    id: idLabel
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - 26 - nameLabel.width - parent.spacing * 2)
                    visible: row.modelData.id !== row.modelData.name
                    text: row.modelData.id
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideMiddle
                }
            }
        }
    }
}
