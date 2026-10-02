import QtQuick
import qs.Common
import qs.Widgets

// The day a run of messages was written on.
//
// Quieter than the unread divider, which is the line that matters: this one
// only answers "when", so it takes the conversation's own muted colour and no
// rules either side.
Item {
    id: root

    property string text: ""

    implicitHeight: visible ? label.implicitHeight + Theme.spacingM : 0
    height: implicitHeight

    StyledText {
        id: label
        anchors.centerIn: parent
        text: root.text
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
    }
}
