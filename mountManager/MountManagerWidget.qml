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
            width: pillRow.implicitWidth + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
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
        StyledRect {
            readonly property real verticalPadding: Theme.spacingS

            width: parent.widgetThickness
            height: Math.max(parent.widgetThickness, vPillContent.implicitHeight + verticalPadding * 2)
            radius: Theme.cornerRadius
            color: root.removableMounted ? Theme.withAlpha(root.accent, 0.16) : "transparent"

            Column {
                id: vPillContent

                anchors.centerIn: parent
                spacing: 0

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: root.pillIcon
                    size: root.iconSize
                    color: root.accent
                    filled: root.removableMounted
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
