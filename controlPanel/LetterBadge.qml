import QtQuick
import qs.Common
import qs.Widgets

// The vimium-style hint: shows which key toggles the thing it's next to.
Rectangle {
    id: root

    property string letter: ""
    property bool active: false

    width: 20
    height: 20
    radius: 4
    color: active ? Theme.primary : Theme.withAlpha(Theme.primary, 0.18)

    StyledText {
        anchors.centerIn: parent
        text: root.letter
        font.pixelSize: Theme.fontSizeSmall - 1
        font.weight: Font.Bold
        color: root.active ? Theme.onPrimary : Theme.primary
    }
}
