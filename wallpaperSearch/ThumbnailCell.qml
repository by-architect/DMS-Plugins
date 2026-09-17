import QtQuick
import qs.Common
import qs.Widgets

// One grid cell: a thumbnail, a selection ring when it's the current index,
// and a status overlay while a Wallhaven pick is downloading.
Rectangle {
    id: root

    required property var item
    property bool isCurrent: false
    property bool isBusy: false

    signal activated

    color: Theme.surfaceContainerHighest
    radius: Theme.cornerRadius
    border.color: isCurrent ? Theme.primary : "transparent"
    border.width: isCurrent ? 3 : 0
    clip: true

    Image {
        id: thumb

        anchors.fill: parent
        anchors.margins: root.isCurrent ? 3 : 0
        source: root.item.thumb
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
        sourceSize.width: 400
    }

    DankSpinner {
        anchors.centerIn: parent
        visible: thumb.status === Image.Loading
        running: visible
        size: 22
    }

    DankIcon {
        anchors.centerIn: parent
        visible: thumb.status === Image.Error
        name: "broken_image"
        size: 24
        color: Theme.surfaceVariantText
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha(Theme.background, 0.7)
        visible: root.isBusy

        DankSpinner {
            anchors.centerIn: parent
            running: root.isBusy
            size: 28
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }
}
