import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets as DC

// One icon in half the bar's width -- two of them sit side by side, which
// DankBar's own column cannot do -- with an optional count on its corner.
Item {
    id: root

    property string icon: ""
    property real iconSize: 16
    property color iconColor: Theme.surfaceText
    property bool filled: false
    property bool pulsing: false
    property string badge: ""
    property string tip: ""
    property var tipHost: null

    implicitWidth: root.iconSize
    implicitHeight: root.iconSize + 4

    DC.DIcon {
        id: glyph

        anchors.centerIn: parent
        name: root.icon
        size: root.iconSize
        color: root.iconColor
        filled: root.filled

        SequentialAnimation on opacity {
            running: root.pulsing && root.visible
            loops: Animation.Infinite
            onRunningChanged: if (!running)
                glyph.opacity = 1
            NumberAnimation {
                to: 0.3
                duration: 450
            }
            NumberAnimation {
                to: 1
                duration: 450
            }
        }
    }

    Rectangle {
        visible: root.badge !== ""
        anchors.right: parent.right
        anchors.top: parent.top
        width: Math.max(height, badgeText.implicitWidth + 4)
        height: Math.round(root.iconSize * 0.62)
        radius: height / 2
        color: Theme.error

        StyledText {
            id: badgeText

            anchors.centerIn: parent
            text: root.badge
            wrapMode: Text.NoWrap
            font.pixelSize: Math.max(7, Math.round(parent.height * 0.8))
            font.weight: Font.Bold
            color: Theme.surface
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onEntered: root.tipHost?.showTip(root, root.tip)
        onExited: root.tipHost?.hideTip(root)
    }
}
