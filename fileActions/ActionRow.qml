import QtQuick
import qs.Common
import qs.Widgets
import "actions.js" as Actions

// One running action: what it is, how far along, and what it is on right now.
StyledRect {
    id: row

    property var action: null
    property real nowMs: 0

    readonly property real fraction: action && isFinite(action.percent) && action.percent >= 0 ? action.percent / 100 : 0
    readonly property bool indeterminate: !action || !isFinite(action.percent) || action.percent < 0
    readonly property color accent: !action ? Theme.primary : (action.stale ? Theme.warning : (action.paused ? Theme.surfaceVariantText : Theme.primary))

    implicitHeight: content.implicitHeight + Theme.spacingM * 2
    height: implicitHeight
    radius: Theme.cornerRadius
    color: Theme.surfaceContainerHigh

    Row {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingM
        spacing: Theme.spacingM

        Rectangle {
            id: iconWell

            width: 34
            height: 34
            radius: width / 2
            color: Theme.withAlpha(row.accent, 0.16)
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                anchors.centerIn: parent
                name: row.action ? Actions.iconFor(row.action.command) : "bolt"
                size: Theme.iconSize - 4
                color: row.accent
            }
        }

        Column {
            width: content.width - iconWell.width - content.spacing
            spacing: Theme.spacingXS

            Item {
                width: parent.width
                height: titleText.implicitHeight

                StyledText {
                    id: titleText

                    anchors.left: parent.left
                    anchors.right: statusText.left
                    anchors.rightMargin: Theme.spacingS
                    text: row.action ? Actions.titleOf(row.action) : ""
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideMiddle
                }

                StyledText {
                    id: statusText

                    anchors.right: parent.right
                    anchors.baseline: titleText.baseline
                    // A stalled or paused action says so where the number
                    // would be: a frozen "94%" is what made it look fine.
                    text: {
                        if (!row.action)
                            return "";
                        if (row.action.stale)
                            return "stalled";
                        if (row.action.paused)
                            return "paused";
                        return Actions.percentText(row.action.percent);
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: row.action && (row.action.stale || row.action.paused) ? row.accent : Theme.surfaceVariantText
                }
            }

            Rectangle {
                width: parent.width
                height: 4
                radius: 2
                color: Theme.surfaceContainerHighest

                Rectangle {
                    width: row.indeterminate ? parent.width : parent.width * row.fraction
                    height: parent.height
                    radius: parent.radius
                    color: row.accent
                    opacity: row.indeterminate ? 0.35 : 1

                    Behavior on width {
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Theme.standardEasing
                        }
                    }
                }
            }

            StyledText {
                width: parent.width
                text: row.action ? Actions.subtitleOf(row.action) : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
                visible: text.length > 0
            }

            StyledText {
                width: parent.width
                text: row.action ? Actions.baseName(row.action.currentFile) : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.outline
                elide: Text.ElideMiddle
                visible: text.length > 0
            }
        }
    }
}
