import QtQuick
import qs.Common
import qs.Widgets
import "mounts.js" as Mounts

// One device: what it is, where it is mounted, and the buttons for the things
// that may actually be done to it. A system mount gets no unmount button at
// all rather than one that fails — there is no useful outcome behind it.
StyledRect {
    id: row

    property var device: null
    readonly property bool busy: device ? MountService.isBusy(device.path) : false
    readonly property string busyVerb: device ? MountService.busyVerb(device.path) : ""
    readonly property color accent: {
        if (!device)
            return Theme.surfaceVariantText;
        if (device.locked)
            return Theme.warning;
        if (device.mounted)
            return device.system ? Theme.surfaceVariantText : Theme.primary;
        return Theme.surfaceVariantText;
    }

    implicitHeight: content.implicitHeight + Theme.spacingM * 2
    height: implicitHeight
    radius: Theme.cornerRadius
    color: device && device.mounted && !device.system ? Theme.surfaceContainerHigh : Theme.surfaceContainer

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
                name: row.device ? Mounts.iconFor(row.device) : "hard_drive"
                size: Theme.iconSize - 4
                color: row.accent
                visible: !row.busy
            }

            DankSpinner {
                anchors.centerIn: parent
                size: Theme.iconSize - 6
                color: row.accent
                visible: row.busy
                running: row.busy
            }
        }

        Column {
            width: content.width - iconWell.width - actions.width - content.spacing * 2
            spacing: 2
            anchors.verticalCenter: parent.verticalCenter

            StyledText {
                width: parent.width
                text: row.device ? Mounts.titleOf(row.device) : ""
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                text: {
                    if (!row.device)
                        return "";
                    if (row.busy)
                        return row.busyVerb === "mount" ? "mounting…" : (row.busyVerb === "unmount" ? "unmounting…" : "ejecting…");
                    return Mounts.subtitleOf(row.device);
                }
                font.pixelSize: Theme.fontSizeSmall
                color: row.device && row.device.mounted && !row.device.system ? Theme.primary : Theme.surfaceVariantText
                elide: Text.ElideMiddle
            }

            StyledText {
                width: parent.width
                text: row.device ? Mounts.detailOf(row.device) + (row.device.system ? " · system" : "") : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.outline
                elide: Text.ElideRight
                visible: text.length > 0
            }

            // A locked volume has no actions here by design; what it has is the
            // one command that unlocks it, ready to paste into a terminal.
            Row {
                width: parent.width
                spacing: Theme.spacingXS
                visible: row.device ? row.device.locked : false

                StyledText {
                    width: parent.width - copyUnlock.width - Theme.spacingXS
                    text: row.device ? Mounts.unlockHint(row.device) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    isMonospace: true
                    color: Theme.surfaceVariantText
                    elide: Text.ElideMiddle
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankActionButton {
                    id: copyUnlock

                    iconName: "content_copy"
                    buttonSize: 24
                    iconSize: Theme.iconSize - 10
                    iconColor: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: MountService.copyText(Mounts.unlockHint(row.device), "unlock command")
                }
            }

            Rectangle {
                width: parent.width
                height: 4
                radius: 2
                color: Theme.surfaceContainerHighest
                visible: row.device ? row.device.mounted && row.device.usePercent >= 0 : false

                Rectangle {
                    width: parent.width * (row.device && row.device.usePercent >= 0 ? row.device.usePercent / 100 : 0)
                    height: parent.height
                    radius: parent.radius
                    // Nearly-full is worth noticing on a disk in a way it is
                    // not on a transfer, so the bar changes colour rather than
                    // leaving the number to be read.
                    color: row.device && row.device.usePercent >= 90 ? Theme.error : (row.device && row.device.usePercent >= 75 ? Theme.warning : row.accent)
                }
            }
        }

        Row {
            id: actions

            spacing: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter

            DankActionButton {
                visible: row.device ? row.device.mounted && !!row.device.mountpoint : false
                enabled: !row.busy
                iconName: "folder_open"
                buttonSize: 30
                iconColor: Theme.surfaceVariantText
                tooltipText: "Open " + (row.device ? row.device.mountpoint : "")
                onClicked: MountService.openMount(row.device)
            }

            DankActionButton {
                visible: row.device ? row.device.mounted && !!row.device.mountpoint : false
                enabled: !row.busy
                iconName: "content_copy"
                buttonSize: 30
                iconColor: Theme.surfaceVariantText
                tooltipText: "Copy mount path"
                onClicked: MountService.copyText(row.device.mountpoint, "mount path")
            }

            DankActionButton {
                visible: row.device ? row.device.canMount : false
                enabled: !row.busy
                iconName: "play_arrow"
                buttonSize: 30
                iconColor: Theme.primary
                tooltipText: "Mount"
                onClicked: MountService.mount(row.device)
            }

            DankActionButton {
                visible: row.device ? row.device.canUnmount : false
                enabled: !row.busy
                iconName: "eject"
                buttonSize: 30
                iconColor: Theme.surfaceText
                tooltipText: "Unmount"
                onClicked: MountService.unmount(row.device)
            }

            DankActionButton {
                visible: row.device ? row.device.canEject : false
                enabled: !row.busy
                iconName: "power_settings_new"
                buttonSize: 30
                iconColor: Theme.error
                tooltipText: "Unmount everything on this disk and power it off"
                onClicked: MountService.eject(row.device)
            }
        }
    }
}
