import QtQuick
import Quickshell.Wayland
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "actions.js" as Actions

// The pill is the newest running action and nothing else: its icon, its
// percentage, and a hairline of progress along the bottom. Everything that
// needs a list lives in the popout.
PluginComponent {
    id: root

    layerNamespacePlugin: "file-actions"

    readonly property var current: FileActionsService.current
    readonly property int activeCount: FileActionsService.activeCount
    readonly property bool busy: activeCount > 0
    readonly property string pillIcon: current ? Actions.iconFor(current.command) : "content_copy"
    readonly property string pillText: current ? (current.stale ? "!" : Actions.percentText(current.percent)) : ""
    readonly property real fraction: current && isFinite(current.percent) && current.percent >= 0 ? current.percent / 100 : 0
    readonly property color accent: !busy ? Theme.surfaceVariantText : (current && current.stale ? Theme.warning : Theme.primary)

    popoutWidth: 460

    // Right-click clears the finished list; left-click is the popout.
    pillRightClickAction: () => FileActionsService.clearHistory()

    function applyIdleVisibility() {
        if (FileActionsService.hideWhenIdle)
            root.setVisibilityOverride(root.busy);
        else
            root.clearVisibilityOverride();
    }

    onBusyChanged: applyIdleVisibility()

    // Counted in and out, so the service only polls while a pill exists.
    Component.onCompleted: {
        FileActionsService.consumers++;
        FileActionsService.addPill(root);
        applyIdleVisibility();
    }
    Component.onDestruction: {
        FileActionsService.consumers = Math.max(0, FileActionsService.consumers - 1);
        FileActionsService.removePill(root);
        if (root.peeking)
            root._endPeek(false);
    }

    Connections {
        target: FileActionsService

        function onHideWhenIdleChanged() {
            root.applyIdleVisibility();
        }

        function onActionStarted(action, screenName) {
            if ((root.parentScreen ? root.parentScreen.name : "") === screenName)
                root.peek();
        }
    }

    // ---------------------------------------------------------------- peek
    // A new action opens the popout for a few seconds, the way a message
    // would: with no keyboard focus and without the screen-wide click catcher
    // an ordinary popout brings, because the action was almost certainly just
    // started from a terminal that is still being typed into. Hovering it
    // keeps it up; clicking the pill while it shows turns it into the
    // ordinary popout, keyboard and all. One already open is left alone, and
    // so is another popout on the same screen, which this would replace.
    readonly property int peekMs: 3000
    property bool peeking: false
    property bool peekHovered: false
    property var _popoutHandle: null

    // PluginComponent keeps its popout to itself (it is an id in that file),
    // so it is found among the children by what it has: the two properties
    // the peek turns down for its few seconds.
    function _findPopout() {
        if (root._popoutHandle)
            return root._popoutHandle;
        const kids = root.data;
        for (let i = 0; i < kids.length; i++) {
            const o = kids[i];
            if (o && o.pluginContent !== undefined && o.customKeyboardFocus !== undefined && o.backgroundInteractive !== undefined) {
                root._popoutHandle = o;
                break;
            }
        }
        return root._popoutHandle;
    }

    function _screenHasPopout() {
        const name = root.parentScreen ? root.parentScreen.name : "";
        const current = PopoutManager.currentPopoutsByScreen[name];
        return !!current && current.shouldBeVisible === true;
    }

    function peek() {
        if (root.peeking) {
            peekTimer.restart();
            return;
        }
        if (!root.hasPopout || !root.effectiveVisible || root.interactionActive || root._screenHasPopout())
            return;
        const popout = root._findPopout();
        if (!popout)
            return;
        popout.customKeyboardFocus = WlrKeyboardFocus.None;
        popout.backgroundInteractive = false;
        root.peeking = true;
        root.triggerPopout();
        // Set after opening, or triggerPopout would have run it instead.
        root.pillClickAction = () => root._endPeek(false);
        peekTimer.restart();
    }

    // Puts back what the peek turned down. close=false keeps the popout open,
    // as the ordinary popout from then on.
    function _endPeek(close) {
        peekTimer.stop();
        root.pillClickAction = null;
        root.peeking = false;
        root.peekHovered = false;
        if (close)
            root.closePopout();
        const popout = root._popoutHandle;
        if (popout) {
            popout.customKeyboardFocus = null;
            popout.backgroundInteractive = true;
        }
    }

    // Closed some other way while peeking -- its own close button, another
    // popout taking the screen.
    onInteractionActiveChanged: {
        if (!root.interactionActive && root.peeking)
            root._endPeek(false);
    }

    Timer {
        id: peekTimer

        interval: root.peekMs
        onTriggered: {
            if (root.peekHovered)
                restart();
            else
                root._endPeek(true);
        }
    }

    horizontalBarPill: Component {
        StyledRect {
            // The pill's size on the bar comes from these IMPLICIT values:
            // BasePill reads implicitWidth/implicitHeight and adds the bar's
            // own widget padding around them. Setting width/height instead
            // leaves the implicit size at zero, the pill collapses to bare
            // padding, and on a vertical bar every icon ends up pressed
            // against its neighbours. `parent` here is BasePill's Loader,
            // which has no widgetThickness — that comes from root.
            implicitWidth: pillRow.implicitWidth + Theme.spacingS * 2
            implicitHeight: root.widgetThickness
            radius: height / 2
            color: root.busy ? Theme.withAlpha(root.accent, 0.16) : "transparent"

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.pillIcon
                    size: root.iconSize
                    color: root.accent
                    filled: root.busy
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.pillText.length > 0
                    text: root.pillText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root.accent
                }

                // Only the newest action gets the pill; the rest are a count,
                // so two copies at once cannot hide behind one percentage.
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.activeCount > 1
                    text: "+" + (root.activeCount - 1)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.spacingXS
                anchors.bottomMargin: 3
                width: (parent.width - Theme.spacingXS * 2) * root.fraction
                height: 2
                radius: 1
                color: root.accent
                visible: root.busy && root.fraction > 0

                Behavior on width {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            // Implicit size only — see the horizontal pill. The icon sits in a
            // round well of its own rather than colouring the whole pill, so
            // the highlight is a circle instead of a short wide slab.
            implicitWidth: root.widgetThickness
            implicitHeight: vPillContent.implicitHeight

            Column {
                id: vPillContent

                anchors.centerIn: parent
                spacing: 1

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: root.iconSize + 10
                    height: width
                    radius: width / 2
                    color: root.busy ? Theme.withAlpha(root.accent, 0.16) : "transparent"

                    DankIcon {
                        anchors.centerIn: parent
                        name: root.pillIcon
                        size: root.iconSize
                        color: root.accent
                        filled: root.busy
                    }
                }

                // No room for "+1" as well, so a vertical bar shows the count
                // instead of the percentage once a second action starts.
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.busy
                    text: root.activeCount > 1 ? "×" + root.activeCount : root.pillText
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: root.accent
                }
            }
        }
    }

    popoutContent: Component {
        FileActionsPopout {
            HoverHandler {
                onHoveredChanged: root.peekHovered = hovered
            }
        }
    }
}
