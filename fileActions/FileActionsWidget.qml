import QtQuick
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
    Component.onCompleted: applyIdleVisibility()

    Connections {
        target: FileActionsService

        function onHideWhenIdleChanged() {
            root.applyIdleVisibility();
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
        FileActionsPopout {}
    }
}
