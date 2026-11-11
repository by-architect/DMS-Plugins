import QtQuick
import qs.Common
import qs.DCommon.Widgets as DC

// A switch on a phone's block: an icon on a pill, filled while it is on.
// It pulses while the phone is switching it, turns red when a click needs
// a second one to go ahead, and its icon turns red when switching failed.
Item {
    id: root

    property string icon: ""
    property real iconSize: 14
    // true on, false off, null not known yet
    property var isOn: null
    property bool busy: false
    property bool armed: false
    property bool failed: false
    property string tip: ""
    property var tipHost: null

    signal clicked

    implicitWidth: root.iconSize + 4
    implicitHeight: root.iconSize + 6

    Rectangle {
        id: pill

        anchors.fill: parent
        radius: Math.min(width, height) / 2
        color: root.armed ? Theme.withAlpha(Theme.error, 0.3) : (root.isOn === true ? Theme.withAlpha(Theme.primary, 0.28) : (mouse.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.1) : "transparent"))

        SequentialAnimation on opacity {
            running: root.busy && root.visible
            loops: Animation.Infinite
            onRunningChanged: if (!running)
                pill.opacity = 1
            NumberAnimation {
                to: 0.35
                duration: 450
            }
            NumberAnimation {
                to: 1
                duration: 450
            }
        }
    }

    DC.DIcon {
        anchors.centerIn: parent
        name: root.icon
        size: root.iconSize
        filled: root.isOn === true
        color: root.failed || root.armed ? Theme.error : (root.isOn === true ? Theme.primary : Theme.surfaceVariantText)
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.PointingHandCursor
        onEntered: root.tipHost?.showTip(root, root.tip)
        onExited: root.tipHost?.hideTip(root)
        onClicked: root.clicked()
    }

    // The words change while the pointer rests on it: switching, done, why not.
    onTipChanged: if (mouse.containsMouse)
        root.tipHost?.showTip(root, root.tip)
}
