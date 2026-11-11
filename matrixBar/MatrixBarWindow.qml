pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets as DC

// The bar on one screen's left edge: DankBar's own surface -- its colour,
// transparency, rounding, gap to the screen edge and shadow, all read from
// the main bar's settings -- holding one block per machine of the matrix.
// It reserves its width, so windows tile beside it rather than under it.
PanelWindow {
    id: win

    property var modelData: null

    screen: modelData

    // The bar whose look this copies: the first one switched on.
    readonly property var cfg: {
        const bars = SettingsData.barConfigs || [];
        return bars.find(b => b && b.enabled !== false) ?? bars[0] ?? null;
    }
    readonly property real dpr: typeof CompositorService.getScreenScale === "function" ? CompositorService.getScreenScale(win.screen) : 1

    // DankBar drops its gap and its corners while a window is maximized on
    // the screen; so does this.
    readonly property bool flatten: (win.cfg?.maximizeDetection ?? true) && typeof CompositorService.maximizedWindowOnScreen === "function" && CompositorService.maximizedWindowOnScreen(win.screen?.name ?? "")
    readonly property real gap: win.flatten || (win.cfg?.attachToScreenEdge ?? false) ? 0 : (win.cfg?.spacing ?? 4)

    // DankBar's thickness for its padding, but never too narrow for two bars
    // side by side with a number under each.
    readonly property real dankThickness: Theme.barThickness(win.cfg?.innerPadding ?? 2, win.dpr)
    readonly property int setWidth: MatrixBarService.barWidth
    readonly property real thickness: Theme.snapEven(win.setWidth > 0 ? win.setWidth : Math.max(win.dankThickness, Theme.fontSizeSmall * 4), win.dpr)
    readonly property real band: Theme.px(win.thickness + win.gap, win.dpr)

    readonly property real radius: (win.cfg?.squareCorners ?? false) || win.flatten ? 0 : Theme.windowRadius
    readonly property color surfaceColor: {
        const base = typeof SettingsData.barSurfaceColor === "function" ? SettingsData.barSurfaceColor(win.cfg) : Theme.surface;
        const alpha = typeof SettingsData.barTransparency === "function" ? SettingsData.barTransparency(win.cfg) : (win.cfg?.transparency ?? 1);
        return Theme.withAlpha(base, alpha);
    }

    // The shadow DankBar casts, and the room it needs beside the bar.
    readonly property bool shadowOn: Theme.elevationEnabled && (SettingsData.barElevationEnabled ?? true) && !(win.cfg?.noBackground ?? false)
    readonly property string shadowDirection: Theme.elevationLightDirection === "autoBar" ? "left" : Theme.elevationLightDirection
    readonly property real shadowRoom: win.shadowOn && typeof Theme.elevationRenderPadding === "function" ? Theme.snap(Theme.elevationRenderPadding(Theme.elevationLevel2, win.shadowDirection, Theme.spacingXS, 8, 16), win.dpr) : 0

    // The blocks: as wide as the bar less a margin, filled like DankBar's
    // widget pills.
    readonly property real blockMargin: Math.max(2, Math.round((win.thickness - Theme.barWidgetThickness(win.cfg?.innerPadding ?? 2, win.dpr)) / 4))
    readonly property real blockWidth: win.thickness - win.blockMargin * 2
    readonly property color blockColor: {
        if (win.cfg?.noBackground ?? false)
            return "transparent";
        const t = typeof SettingsData.barWidgetTransparency === "function" ? SettingsData.barWidgetTransparency(win.cfg) : (win.cfg?.widgetTransparency ?? 1);
        return Theme.widgetBackgroundHasAlpha ? Theme.blendAlpha(Theme.widgetBaseBackgroundColor, t) : Theme.withAlpha(Theme.widgetBaseBackgroundColor, t);
    }
    readonly property real inset: Math.max(Theme.spacingXS, win.cfg?.barInsetPadding ?? 4)

    color: "transparent"

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "dms:plugins:matrix-bar"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        left: true
        top: true
        bottom: true
    }

    implicitWidth: win.band + win.shadowRoom
    // Only the bar itself: the window is wider by the shadow's room.
    exclusiveZone: win.band
    mask: Region {
        item: inputStrip
    }

    Item {
        id: inputStrip

        width: win.band
        height: parent.height
    }

    // Counted in and out, so the machines are only read while a bar is up.
    Component.onCompleted: MatrixBarService.consumers++
    Component.onDestruction: MatrixBarService.consumers = Math.max(0, MatrixBarService.consumers - 1)

    // ------------------------------------------------------------ the bar
    Item {
        id: body

        x: Theme.px(win.gap, win.dpr)
        y: Theme.px(win.gap, win.dpr)
        width: win.thickness
        height: parent.height - y * 2

        ElevationShadow {
            anchors.fill: parent
            visible: win.shadowOn
            shadowEnabled: win.shadowOn
            level: Theme.elevationLevel2
            direction: win.shadowDirection
            fallbackOffset: Theme.spacingXS
            targetRadius: win.radius
            targetColor: "transparent"
        }

        Rectangle {
            anchors.fill: parent
            radius: win.radius
            color: (win.cfg?.noBackground ?? false) ? "transparent" : win.surfaceColor
        }

        Flickable {
            id: flick

            anchors.fill: parent
            anchors.topMargin: win.inset
            anchors.bottomMargin: win.inset
            contentWidth: width
            contentHeight: blocks.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // Longer than the screen: the wheel scrolls it.
            interactive: contentHeight > height

            Column {
                id: blocks

                width: flick.width
                spacing: Theme.spacingXS

                Repeater {
                    model: MatrixBarService.hosts

                    delegate: HostBlock {
                        required property var modelData

                        anchors.horizontalCenter: parent.horizontalCenter
                        host: modelData
                        result: MatrixBarService.results[modelData.name] ?? null
                        collapsed: MatrixBarService.collapsedHosts.indexOf(modelData.name) >= 0
                        blockWidth: win.blockWidth
                        blockColor: win.blockColor
                        tipHost: win
                    }
                }

                // Nothing to show yet, or nothing to show at all: say which.
                Item {
                    width: win.blockWidth
                    height: placeholder.implicitHeight + Theme.spacingS * 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: MatrixBarService.hosts.length === 0

                    readonly property string why: MatrixBarService.discoveryError !== "" ? MatrixBarService.discoveryError : (MatrixBarService.discovering || MatrixBarService.discoveredMs === 0 ? "Looking for matrix's machines…" : "matrix lists no machines")

                    Rectangle {
                        anchors.fill: parent
                        radius: Math.min(width / 2, Theme.cornerRadius)
                        color: win.blockColor
                    }

                    DC.DIcon {
                        id: placeholder

                        anchors.centerIn: parent
                        name: MatrixBarService.discoveryError !== "" ? "error" : "hourglass_empty"
                        size: Theme.iconSize - 4
                        color: MatrixBarService.discoveryError !== "" ? Theme.error : Theme.surfaceVariantText
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: win.showTip(parent, parent.why)
                        onExited: win.hideTip(parent)
                        onClicked: MatrixBarService.refresh()
                    }
                }
            }
        }
    }

    // --------------------------------------------------------- the tooltip
    // A popup beside the bar: the bar's own window is too narrow to hold
    // one. Shown after a short rest on something, gone the moment the
    // pointer leaves it; moving to the next thing just moves it.
    property Item tipTarget: null
    property string tipText: ""
    property bool tipWanted: false

    function showTip(item, text) {
        if (!item || !text) {
            hideTip(item);
            return;
        }
        win.tipTarget = item;
        win.tipText = text;
        win.tipWanted = true;
        if (tip.visible)
            Qt.callLater(win._placeTip);
        else
            tipDelay.restart();
    }

    function hideTip(item) {
        if (item && item !== win.tipTarget)
            return;
        win.tipWanted = false;
        tipDelay.stop();
        tipGrace.restart();
    }

    function _placeTip() {
        if (!win.tipTarget)
            return;
        const p = win.tipTarget.mapToItem(null, 0, 0);
        tip.anchor.rect.x = win.band;
        tip.anchor.rect.y = Math.round(p.y);
        tip.anchor.rect.width = 1;
        tip.anchor.rect.height = Math.max(1, Math.round(win.tipTarget.height));
        if (tip.visible)
            tip.anchor.updateAnchor();
    }

    Timer {
        id: tipDelay

        interval: 350
        onTriggered: {
            if (!win.tipWanted)
                return;
            win._placeTip();
            tip.visible = true;
        }
    }

    // A moment's grace: going from one thing to the one below it passes over
    // the gap between them.
    Timer {
        id: tipGrace

        interval: 120
        onTriggered: {
            if (!win.tipWanted) {
                tip.visible = false;
                win.tipTarget = null;
            }
        }
    }

    PopupWindow {
        id: tip

        visible: false
        color: "transparent"
        anchor.window: win
        anchor.edges: Edges.Right
        anchor.gravity: Edges.Right
        anchor.margins.left: Theme.spacingS
        implicitWidth: bubble.width
        implicitHeight: bubble.height

        Rectangle {
            id: bubble

            width: tipLabel.implicitWidth + Theme.spacingM * 2
            height: tipLabel.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.outlineVariant

            StyledText {
                id: tipLabel

                anchors.centerIn: parent
                text: win.tipText
                textFormat: Text.PlainText
                wrapMode: Text.NoWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
    }
}
