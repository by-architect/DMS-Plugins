import QtQuick
import QtQuick.Shapes
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets as DC

// A circle with a number or an icon in it, and a ring around it: the ring is
// progress (value 0..1), a turning arc while something runs without a
// known progress (spinning), or a plain colour that says how things stand.
// Sized like DankBar's own battery ring.
Item {
    id: root

    property real diameter: 22
    property real stroke: Math.max(1.5, Math.round(diameter * 2 / 19))
    property real value: -1            // 0..1 drawn as an arc; below 0 none
    property bool spinning: false
    property color ringColor: Theme.primary
    property color trackColor: Theme.withAlpha(Theme.surfaceText, 0.12)
    property string text: ""
    property string icon: ""
    property color contentColor: Theme.surfaceText
    property real textSize: 10
    property bool iconSpins: false
    property string tip: ""
    property var tipHost: null

    implicitWidth: root.diameter
    implicitHeight: root.diameter

    readonly property real _r: Math.max(0, root.diameter / 2 - root.stroke / 2)

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: root.trackColor
            strokeWidth: root.stroke
            capStyle: ShapePath.FlatCap

            PathAngleArc {
                centerX: root.diameter / 2
                centerY: root.diameter / 2
                radiusX: root._r
                radiusY: root._r
                startAngle: -90
                sweepAngle: 360
            }
        }

        ShapePath {
            fillColor: "transparent"
            strokeColor: root.value > 0 && !root.spinning ? root.ringColor : "transparent"
            strokeWidth: root.stroke
            capStyle: root.value >= 1 ? ShapePath.FlatCap : ShapePath.RoundCap

            PathAngleArc {
                centerX: root.diameter / 2
                centerY: root.diameter / 2
                radiusX: root._r
                radiusY: root._r
                startAngle: -90
                sweepAngle: Math.max(0, Math.min(1, root.value)) * 360
            }
        }
    }

    // Running, progress unknown: a quarter arc going round.
    Shape {
        id: spinner

        anchors.fill: parent
        visible: root.spinning
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: root.ringColor
            strokeWidth: root.stroke
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.diameter / 2
                centerY: root.diameter / 2
                radiusX: root._r
                radiusY: root._r
                startAngle: -90
                sweepAngle: 100
            }
        }

        RotationAnimation on rotation {
            running: root.spinning && root.visible
            from: 0
            to: 360
            duration: 1400
            loops: Animation.Infinite
        }
    }

    StyledText {
        anchors.centerIn: parent
        visible: root.icon === ""
        text: root.text
        wrapMode: Text.NoWrap
        font.pixelSize: root.textSize
        font.weight: Font.Medium
        font.features: {
            "tnum": 1
        }
        color: root.contentColor
    }

    DC.DIcon {
        id: glyph

        anchors.centerIn: parent
        visible: root.icon !== ""
        name: root.icon
        size: Math.round(root.diameter * 0.6)
        color: root.contentColor

        RotationAnimation on rotation {
            running: root.iconSpins && root.visible
            from: 360
            to: 0
            duration: 2000
            loops: Animation.Infinite
            onRunningChanged: if (!running)
                glyph.rotation = 0
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
