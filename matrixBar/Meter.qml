import QtQuick
import qs.Common
import qs.Widgets
import "bar.js" as Bar

// One upright bar that fills from the bottom, with its percentage under it.
// The fill is a full-height capsule shown only up to the level, so its
// rounded foot always matches the track's, however low the level.
Item {
    id: root

    property real value: -1            // 0..100; below 0 unknown
    property real barWidth: 8
    property real barHeight: 36
    // Where the colour turns: warning, then error. inverse: low is bad
    // (a battery).
    property real warnAt: 75
    property real dangerAt: 90
    property bool inverse: false
    property bool showLabel: true
    property string label: Bar.pctLabel(root.value)
    property real labelSize: 10
    property bool dim: false
    property string tip: ""
    property var tipHost: null

    readonly property bool known: isFinite(root.value) && root.value >= 0
    readonly property color levelColor: {
        if (!root.known || root.dim)
            return Theme.surfaceVariantText;
        if (root.inverse)
            return root.value <= root.dangerAt ? Theme.error : (root.value <= root.warnAt ? Theme.warning : Theme.primary);
        return root.value >= root.dangerAt ? Theme.error : (root.value >= root.warnAt ? Theme.warning : Theme.primary);
    }

    implicitWidth: Math.max(root.barWidth, root.showLabel ? number.implicitWidth : 0)
    implicitHeight: root.barHeight + (root.showLabel ? 2 + number.implicitHeight : 0)

    Rectangle {
        id: track

        anchors.horizontalCenter: parent.horizontalCenter
        width: root.barWidth
        height: root.barHeight
        radius: width / 2
        color: Theme.withAlpha(Theme.surfaceText, 0.12)

        Item {
            anchors.bottom: parent.bottom
            width: parent.width
            height: root.known ? Math.round(parent.height * Math.min(100, root.value) / 100) : 0
            clip: true

            Behavior on height {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Easing.OutCubic
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: track.height
                radius: track.radius
                color: root.levelColor
            }
        }
    }

    StyledText {
        id: number

        visible: root.showLabel
        anchors.top: track.bottom
        anchors.topMargin: 2
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.label
        wrapMode: Text.NoWrap
        font.pixelSize: root.labelSize
        font.features: {
            "tnum": 1
        }
        color: root.known && !root.dim ? Theme.surfaceText : Theme.surfaceVariantText
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onEntered: root.tipHost?.showTip(root, root.tip)
        onExited: root.tipHost?.hideTip(root)
    }
}
