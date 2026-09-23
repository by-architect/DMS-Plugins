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
            width: pillRow.implicitWidth + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
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
        StyledRect {
            readonly property real verticalPadding: Theme.spacingS

            width: parent.widgetThickness
            height: Math.max(parent.widgetThickness, vPillContent.implicitHeight + verticalPadding * 2)
            radius: Theme.cornerRadius
            color: root.busy ? Theme.withAlpha(root.accent, 0.16) : "transparent"

            Column {
                id: vPillContent

                anchors.centerIn: parent
                spacing: 0

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: root.pillIcon
                    size: root.iconSize
                    color: root.accent
                    filled: root.busy
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
