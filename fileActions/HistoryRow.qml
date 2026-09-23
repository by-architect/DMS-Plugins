import QtQuick
import qs.Common
import qs.Widgets
import "actions.js" as Actions

// One action that is over. "ended" is its own outcome, not a success: the
// status file disappeared mid-run and nothing ever said how it went.
StyledRect {
    id: row

    property var action: null
    property real nowMs: 0

    readonly property string phase: action ? action.phase : "done"
    readonly property color accent: phase === "failed" ? Theme.error : (phase === "ended" ? Theme.warning : Theme.success)
    readonly property string glyph: phase === "failed" ? "error" : (phase === "ended" ? "do_not_disturb_on" : "check_circle")

    implicitHeight: content.implicitHeight + Theme.spacingS * 2
    height: implicitHeight
    radius: Theme.cornerRadius
    color: "transparent"

    Row {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingM
        spacing: Theme.spacingM

        DankIcon {
            id: outcomeIcon

            name: row.glyph
            size: Theme.iconSize - 6
            color: row.accent
            anchors.verticalCenter: parent.verticalCenter
        }

        Column {
            width: content.width - outcomeIcon.width - content.spacing
            spacing: 2

            Item {
                width: parent.width
                height: titleText.implicitHeight

                StyledText {
                    id: titleText

                    anchors.left: parent.left
                    anchors.right: timeText.left
                    anchors.rightMargin: Theme.spacingS
                    text: row.action ? Actions.titleOf(row.action) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideMiddle
                }

                StyledText {
                    id: timeText

                    anchors.right: parent.right
                    anchors.baseline: titleText.baseline
                    text: row.action ? Actions.relTime(row.action.endedMs, row.nowMs) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.outline
                }
            }

            StyledText {
                width: parent.width
                text: {
                    if (!row.action)
                        return "";
                    const detail = Actions.doneSubtitleOf(row.action);
                    const label = row.action.command + (row.phase === "failed" ? " failed" : (row.phase === "ended" ? " ended" : ""));
                    return detail ? label + " · " + detail : label;
                }
                font.pixelSize: Theme.fontSizeSmall
                color: row.phase === "failed" ? Theme.error : Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }
    }
}
