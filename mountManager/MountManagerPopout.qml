import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "mounts.js" as Mounts

// Removable first, because that is what someone opens this for, then
// everything else. The list scrolls past a point rather than growing the
// popout off the top of the screen.
PopoutComponent {
    id: popout

    readonly property int maxBodyHeight: 560

    headerText: "Disks"
    detailsText: {
        if (MountService.error)
            return MountService.error;
        if (!MountService.everRead)
            return "Reading devices…";
        const s = MountService.summary;
        const parts = [s.mounted + " mounted"];
        if (s.removable > 0)
            parts.push(s.removable + " removable");
        if (s.locked > 0)
            parts.push(s.locked + " locked");
        return parts.join(" · ");
    }
    showCloseButton: true

    headerActions: Component {
        DankActionButton {
            iconName: "refresh"
            buttonSize: 32
            iconColor: Theme.surfaceVariantText
            tooltipText: "Re-read devices"
            onClicked: MountService.refresh()
        }
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

                StyledText {
                    text: "Removable"
                    leftPadding: Theme.spacingS
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.surfaceVariantText
                    visible: MountService.removableRows.length > 0
                }

                // Counted, not modelled on the array itself: the service
                // replaces both arrays on every read, and a delegate rebuilt
                // every few seconds would drop the row out from under a click.
                Repeater {
                    model: MountService.removableRows.length

                    MountRow {
                        width: body.width
                        device: MountService.removableRows[index]
                    }
                }

                StyledRect {
                    width: body.width
                    height: emptyColumn.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    visible: MountService.removableRows.length === 0

                    Column {
                        id: emptyColumn

                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        DankIcon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: "usb_off"
                            size: Theme.iconSize
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: MountService.everRead ? "Nothing removable plugged in" : "Reading devices…"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                Item {
                    width: body.width
                    height: Theme.spacingXS
                    visible: MountService.internalRows.length > 0
                }

                StyledText {
                    text: "Internal"
                    leftPadding: Theme.spacingS
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.surfaceVariantText
                    visible: MountService.internalRows.length > 0
                }

                Repeater {
                    model: MountService.internalRows.length

                    MountRow {
                        width: body.width
                        device: MountService.internalRows[index]
                    }
                }
            }
        }
    }
}
