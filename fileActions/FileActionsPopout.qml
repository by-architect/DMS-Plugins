import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "actions.js" as Actions

// Running actions on top, finished ones underneath — the order you care about
// them in. The list scrolls past a point rather than growing the popout off
// the top of the screen.
PopoutComponent {
    id: popout

    readonly property int maxBodyHeight: 520

    // Only the "x ago" column needs a clock, and it only needs a slow one.
    property real nowMs: Date.now()

    headerText: "File Actions"
    detailsText: {
        const n = FileActionsService.activeCount;
        if (n > 0)
            return n === 1 ? "1 action running" : n + " actions running";
        if (!FileActionsService.dirPresent)
            return "No status directory yet";
        return "Nothing running right now";
    }
    showCloseButton: true

    headerActions: Component {
        DankActionButton {
            iconName: "delete_sweep"
            buttonSize: 32
            iconColor: Theme.surfaceVariantText
            visible: FileActionsService.history.length > 0
            tooltipText: "Clear finished"
            onClicked: FileActionsService.clearHistory()
        }
    }

    Timer {
        interval: 20000
        repeat: true
        running: true
        onTriggered: popout.nowMs = Date.now()
    }

    Item {
        width: parent.width
        implicitHeight: Math.min(body.implicitHeight, popout.maxBodyHeight)
        height: implicitHeight

        DankFlickable {
            id: flick

            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: body.implicitHeight

            Column {
                id: body

                width: flick.width
                spacing: Theme.spacingS

                // Counted, not modelled on the array itself: the service
                // replaces that array on every poll, and a delegate rebuilt
                // twice a second would restart the progress animation from
                // zero each time. Binding through the index updates the rows
                // in place and only adds or removes one when the count moves.
                Repeater {
                    model: FileActionsService.activeCount

                    ActionRow {
                        width: body.width
                        action: FileActionsService.active[index]
                        nowMs: popout.nowMs
                    }
                }

                // Empty state, but only once a poll has actually happened —
                // "nothing is running" is a claim, not a default.
                StyledRect {
                    width: body.width
                    height: emptyColumn.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    visible: FileActionsService.activeCount === 0

                    Column {
                        id: emptyColumn

                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingL * 2
                        spacing: Theme.spacingXS

                        DankIcon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: FileActionsService.dirPresent ? "check_circle" : "folder_off"
                            size: Theme.iconSize
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: !FileActionsService.everPolled ? "Looking…" : (FileActionsService.dirPresent ? "No file action running" : "Nothing writes here yet")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: FileActionsService.watchDir
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.outline
                            elide: Text.ElideMiddle
                            visible: !FileActionsService.dirPresent
                        }
                    }
                }

                Item {
                    width: body.width
                    height: Theme.spacingXS
                    visible: FileActionsService.history.length > 0
                }

                StyledText {
                    text: "Finished"
                    leftPadding: Theme.spacingS
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.surfaceVariantText
                    visible: FileActionsService.history.length > 0
                }

                Repeater {
                    model: FileActionsService.history.length

                    HistoryRow {
                        width: body.width
                        action: FileActionsService.history[index]
                        nowMs: popout.nowMs
                    }
                }
            }
        }
    }
}
