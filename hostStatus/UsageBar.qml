import QtQuick
import qs.Common
import qs.Widgets

// One labelled bar: what it is, how full, and the numbers. A fraction below
// zero means "not known" -- the track stays empty and the text says why.
Item {
    id: bar

    property string label: ""
    property real fraction: -1
    property string valueText: ""
    property int labelWidth: 60
    property int valueWidth: 112

    // Nearly full is worth noticing without reading the number.
    readonly property color fill: fraction >= 0.9 ? Theme.error : (fraction >= 0.75 ? Theme.warning : Theme.primary)

    implicitHeight: Math.max(labelText.implicitHeight, valueLabel.implicitHeight)
    height: implicitHeight

    StyledText {
        id: labelText

        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: bar.labelWidth
        text: bar.label
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        elide: Text.ElideMiddle
    }

    Rectangle {
        anchors.left: labelText.right
        anchors.right: valueLabel.left
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        height: 6
        radius: 3
        color: Theme.surfaceContainerHighest

        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, bar.fraction))
            height: parent.height
            radius: parent.radius
            color: bar.fill
            visible: bar.fraction > 0
        }
    }

    StyledText {
        id: valueLabel

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: bar.valueWidth
        horizontalAlignment: Text.AlignRight
        text: bar.valueText
        font.pixelSize: Theme.fontSizeSmall
        color: bar.fraction < 0 ? Theme.surfaceVariantText : Theme.surfaceText
        elide: Text.ElideLeft
    }
}
