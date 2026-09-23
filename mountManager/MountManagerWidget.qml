import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "mounts.js" as Mounts

// The pill answers one question at a glance: is there something plugged in
// that I should unmount before pulling it out? Everything else is in the
// popout.
PluginComponent {
    id: root

    layerNamespacePlugin: "mount-manager"

    readonly property var summary: MountService.summary
    readonly property bool hasRemovable: summary.removable > 0
    readonly property bool removableMounted: summary.removableMounted > 0
    readonly property string pillIcon: hasRemovable ? "usb" : "hard_drive"
    readonly property color accent: removableMounted ? Theme.primary : Theme.surfaceVariantText

    popoutWidth: 480

    pillRightClickAction: () => MountService.refresh()

    function applyIdleVisibility() {
        if (MountService.hideWhenIdle)
            root.setVisibilityOverride(root.hasRemovable);
        else
            root.clearVisibilityOverride();
    }

    onHasRemovableChanged: applyIdleVisibility()
    Component.onCompleted: applyIdleVisibility()

    Connections {
        target: MountService

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
            color: root.removableMounted ? Theme.withAlpha(root.accent, 0.16) : "transparent"

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.pillIcon
                    size: root.iconSize
                    color: root.accent
                    filled: root.removableMounted
                }

                // Only removable volumes are counted: the internal ones are
                // always mounted and saying "5" every day teaches nothing.
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.summary.removable > 1 || (root.hasRemovable && root.summary.removableMounted === 0)
                    text: root.summary.removableMounted + "/" + root.summary.removable
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root.accent
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
                    color: root.removableMounted ? Theme.withAlpha(root.accent, 0.16) : "transparent"

                    DankIcon {
                        anchors.centerIn: parent
                        name: root.pillIcon
                        size: root.iconSize
                        color: root.accent
                        filled: root.removableMounted
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.summary.removable > 1
                    text: root.summary.removable
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: root.accent
                }
            }
        }
    }

    popoutContent: Component {
        MountManagerPopout {}
    }
}
