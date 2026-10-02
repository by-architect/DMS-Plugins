import QtQuick
import qs.Common
import qs.Widgets
import "hosts.js" as Hosts

// One host: who it is, whether it answered, and -- when it did -- CPU,
// memory, swap and one bar per real filesystem. Anything else is a sentence
// saying what went wrong and when it was last seen up.
StyledRect {
    id: row

    property var host: null
    property var result: null
    property bool checking: false
    property bool showStorage: true
    property real nowMs: Date.now()

    readonly property int maxFilesystems: 6
    readonly property string hostState: result ? result.state : "checking"
    readonly property var stats: result && result.state === "online" ? result.stats : null
    readonly property var filesystems: stats && showStorage ? stats.filesystems : []
    readonly property color stateColor: {
        switch (hostState) {
        case "online":
            return Theme.success;
        case "unreachable":
        case "error":
            return Theme.error;
        case "auth":
        case "hostkey":
        case "nopass":
            return Theme.warning;
        default:
            return Theme.surfaceVariantText;
        }
    }
    readonly property string stateIcon: {
        switch (hostState) {
        case "online":
            return "dns";
        case "unreachable":
            return "cloud_off";
        case "auth":
            return "lock";
        case "hostkey":
            return "gpp_maybe";
        case "nopass":
            return "key";
        case "error":
            return "error";
        default:
            return "dns";
        }
    }

    implicitHeight: content.implicitHeight + Theme.spacingM * 2
    height: implicitHeight
    radius: Theme.cornerRadius
    color: Theme.surfaceContainerHigh

    Column {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingS

        Item {
            width: parent.width
            height: Math.max(iconWell.height, titleColumn.implicitHeight)

            Rectangle {
                id: iconWell

                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 34
                height: 34
                radius: width / 2
                color: Theme.withAlpha(row.stateColor, 0.16)

                DankIcon {
                    anchors.centerIn: parent
                    name: row.stateIcon
                    size: Theme.iconSize - 4
                    color: row.stateColor
                    visible: !row.checking
                }

                DankSpinner {
                    anchors.centerIn: parent
                    size: Theme.iconSize - 6
                    color: row.stateColor
                    visible: row.checking
                    running: row.checking
                }
            }

            Column {
                id: titleColumn

                anchors.left: iconWell.right
                anchors.right: stateText.left
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    width: parent.width
                    text: row.host ? (row.host.name || row.host.host) : ""
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    width: parent.width
                    text: Hosts.destText(row.host)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideMiddle
                }
            }

            StyledText {
                id: stateText

                anchors.right: connectButton.left
                anchors.rightMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                text: row.result ? Hosts.stateLabel(row.hostState) : "checking…"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: row.stateColor
            }

            DankActionButton {
                id: connectButton

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconName: "terminal"
                buttonSize: 30
                iconColor: Theme.surfaceVariantText
                tooltipText: "Open an ssh session (through SSH Hosts)"
                onClicked: {
                    if (row.host)
                        HostStatusService.openSession(row.host.id);
                }
            }
        }

        Column {
            width: parent.width
            spacing: 6
            visible: !!row.stats

            UsageBar {
                width: parent.width
                label: "CPU"
                fraction: row.stats && row.stats.cpuPercent >= 0 ? row.stats.cpuPercent / 100 : -1
                valueText: row.stats && row.stats.cpuPercent >= 0 ? Hosts.percentText(row.stats.cpuPercent) : "unknown"
            }

            UsageBar {
                width: parent.width
                label: "Memory"
                fraction: row.stats && row.stats.mem ? row.stats.mem.used / row.stats.mem.total : -1
                valueText: row.stats && row.stats.mem ? Hosts.pairText(row.stats.mem.used, row.stats.mem.total) : "unknown"
            }

            UsageBar {
                width: parent.width
                label: "Swap"
                fraction: row.stats && row.stats.swap && row.stats.swap.total > 0 ? row.stats.swap.used / row.stats.swap.total : -1
                valueText: {
                    const swap = row.stats ? row.stats.swap : null;
                    if (!swap)
                        return "unknown";
                    return swap.total > 0 ? Hosts.pairText(swap.used, swap.total) : "none";
                }
            }

            Repeater {
                model: Math.min(row.filesystems.length, row.maxFilesystems)

                UsageBar {
                    required property int index
                    readonly property var fs: row.filesystems[index]

                    width: parent.width
                    label: fs ? fs.mount : ""
                    fraction: fs ? fs.percent / 100 : -1
                    valueText: fs ? Hosts.pairText(fs.used, fs.total) : ""
                }
            }

            StyledText {
                text: "+" + (row.filesystems.length - row.maxFilesystems) + " more filesystems -- dms ipc call hostStatus status lists them all"
                visible: row.filesystems.length > row.maxFilesystems
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.outline
            }
        }

        StyledText {
            width: parent.width
            visible: text.length > 0
            text: {
                const r = row.result;
                if (!r || !r.detail)
                    return "";
                return Hosts.holdsUntilManual(r.state) ? r.detail + " -- not retried on the timer; refresh to try again" : r.detail;
            }
            font.pixelSize: Theme.fontSizeSmall
            color: row.hostState === "online" ? Theme.surfaceVariantText : row.stateColor
            wrapMode: Text.WordWrap
        }

        StyledText {
            width: parent.width
            visible: text.length > 0
            text: {
                const r = row.result;
                if (!r || r.state === "nopass")
                    return "";
                const parts = ["checked " + Hosts.agoText(r.checkedMs, row.nowMs)];
                if (row.stats) {
                    const up = Hosts.uptimeText(row.stats.uptimeSec);
                    if (up)
                        parts.push("up " + up);
                    if (row.stats.load)
                        parts.push("load " + Hosts.loadText(row.stats.load));
                    if (row.stats.ncpu > 0)
                        parts.push(row.stats.ncpu + " CPUs");
                } else if (r.state !== "online") {
                    parts.push(r.lastOnlineMs ? "last online " + Hosts.agoText(r.lastOnlineMs, row.nowMs) : "not seen online since the shell started");
                }
                return parts.join(" · ");
            }
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.outline
            elide: Text.ElideRight
        }
    }
}
