pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets as DC
import "bar.js" as Bar

// One machine's part of the bar, top to bottom:
//
//   name               this machine is underlined
//   CPU | GPU          bars, their percentage under each
//   memory | swap
//   disk 1 | disk 2
//   removable disks    two to a row, as many as there are
//   battery            when it has one
//   signal | network   a phone only: bars, and Wi-Fi or mobile data in one icon
//   calls | data       a phone only: the call state and missed calls, and the
//                      mobile data used this cycle, as a ring
//   ssh                connections to it now
//   Syncthing          working, idle or paused
//   rsync              sync pairs running now
//   backups            backups running now
//
// Hovering anything says what it is and more; a click on the name folds the
// machine away, a right click anywhere connects to it again.
Item {
    id: root

    required property var host
    property var result: null
    property bool collapsed: false
    property real blockWidth: 44
    property color blockColor: Theme.surfaceContainer
    property var tipHost: null

    readonly property var s: root.result ? root.result.stats ?? null : null
    readonly property string state: root.result ? root.result.state : "connecting"
    readonly property bool online: root.state === "online"

    // ------------------------------------------------------------- sizes
    readonly property real pad: 2
    readonly property real colGap: 2
    readonly property real inner: root.blockWidth - root.pad * 2
    readonly property real colW: Math.floor((root.inner - root.colGap) / 2)
    readonly property real labelSize: Math.max(9, Math.round(Theme.fontSizeSmall * 0.78))
    readonly property real barW: Math.max(4, Math.round(root.colW * 0.45 / 2) * 2)
    readonly property real meterH: 34
    readonly property real diskH: 44
    readonly property real removableH: 14
    readonly property real ringD: Math.min(22, root.inner)
    readonly property real iconS: Math.min(18, root.colW)
    readonly property real groupGap: Math.round(Theme.spacingXS * 1.5)
    readonly property real vpad: Theme.spacingS

    implicitWidth: root.blockWidth
    implicitHeight: content.implicitHeight + root.vpad * 2

    readonly property color stateColor: {
        switch (root.state) {
        case "online":
            return root.host.self ? Theme.primary : Theme.surfaceText;
        case "connecting":
            return Theme.surfaceVariantText;
        case "auth":
        case "hostkey":
            return Theme.warning;
        default:
            return Theme.error;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Math.min(width, height) / 2
        color: root.blockColor
    }

    // Right click anywhere: connect again.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: MatrixBarService.reconnect(root.host.name)
    }

    Column {
        id: content

        y: root.vpad
        width: root.inner
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.groupGap

        // ------------------------------------------------------------ name
        Item {
            id: header

            width: parent.width
            height: nameCol.implicitHeight

            Column {
                id: nameCol

                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 1

                DC.DIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: root.host.android ? "smartphone" : (root.s && root.s.battery ? "laptop" : "desktop_windows")
                    size: root.iconS
                    color: root.stateColor
                    filled: root.host.self

                    SequentialAnimation on opacity {
                        running: root.state === "connecting"
                        loops: Animation.Infinite
                        onRunningChanged: if (!running)
                            parent.opacity = 1
                        NumberAnimation {
                            to: 0.35
                            duration: 700
                        }
                        NumberAnimation {
                            to: 1
                            duration: 700
                        }
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Bar.shortName(root.host.name)
                    wrapMode: Text.NoWrap
                    font.pixelSize: root.labelSize
                    font.weight: Font.Bold
                    color: root.online ? Theme.surfaceText : root.stateColor
                }

                // This machine.
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.host.self
                    width: Math.round(root.inner * 0.4)
                    height: 2
                    radius: 1
                    color: Theme.primary
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onEntered: root.tipHost?.showTip(header, Bar.hostTip(root.host, root.result, Date.now()))
                onExited: root.tipHost?.hideTip(header)
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton)
                        MatrixBarService.reconnect(root.host.name);
                    else
                        MatrixBarService.setCollapsed(root.host.name, !root.collapsed);
                }
            }
        }

        // Everything below the name; faded while the numbers are old.
        Column {
            id: details

            visible: !root.collapsed
            width: parent.width
            spacing: root.groupGap
            opacity: root.online ? 1 : 0.45

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.shortDuration
                }
            }

            // CPU | GPU
            Row {
                spacing: root.colGap

                Meter {
                    width: root.colW
                    value: root.s ? root.s.cpu : -1
                    barWidth: root.barW
                    barHeight: root.meterH
                    labelSize: root.labelSize
                    warnAt: 60
                    dangerAt: 80
                    tip: Bar.cpuTip(root.s)
                    tipHost: root.tipHost
                }

                Meter {
                    width: root.colW
                    value: root.s ? root.s.gpu : -1
                    barWidth: root.barW
                    barHeight: root.meterH
                    labelSize: root.labelSize
                    warnAt: 60
                    dangerAt: 80
                    tip: Bar.gpuTip(root.s)
                    tipHost: root.tipHost
                }
            }

            // memory | swap
            Row {
                spacing: root.colGap

                Meter {
                    width: root.colW
                    value: root.s && root.s.mem ? root.s.mem.percent : -1
                    barWidth: root.barW
                    barHeight: root.meterH
                    labelSize: root.labelSize
                    warnAt: 75
                    dangerAt: 90
                    tip: Bar.memTip(root.s)
                    tipHost: root.tipHost
                }

                Meter {
                    width: root.colW
                    value: root.s && root.s.swap ? root.s.swap.percent : -1
                    barWidth: root.barW
                    barHeight: root.meterH
                    labelSize: root.labelSize
                    warnAt: 50
                    dangerAt: 80
                    tip: Bar.swapTip(root.s)
                    tipHost: root.tipHost
                }
            }

            // disk 1 | disk 2 -- "/" (or a phone's internal storage) first,
            // then the biggest; any more are named in disk 2's tooltip.
            Row {
                visible: root.s !== null && root.s.disks.length > 0
                spacing: root.colGap

                Repeater {
                    model: root.s ? Math.min(2, root.s.disks.length) : 0

                    delegate: Meter {
                        required property int index
                        readonly property var disk: root.s.disks[index]

                        width: root.colW
                        value: disk ? disk.percent : -1
                        barWidth: root.barW
                        barHeight: root.diskH
                        labelSize: root.labelSize
                        warnAt: 75
                        dangerAt: 90
                        tip: {
                            const lines = [Bar.diskTip(disk, "Disk " + (index + 1))];
                            if (index === 1)
                                for (const d of root.s.disks.slice(2))
                                    lines.push((d.label || d.mount) + "  " + Bar.percentText(d.percent));
                            return lines.join("\n");
                        }
                        tipHost: root.tipHost
                    }
                }
            }

            // removable disks, two to a row
            Grid {
                visible: root.s !== null && root.s.removable.length > 0
                columns: 2
                columnSpacing: root.colGap
                rowSpacing: root.groupGap

                Repeater {
                    model: root.s ? root.s.removable : []

                    delegate: Meter {
                        required property var modelData

                        width: root.colW
                        value: modelData.percent
                        barWidth: root.barW
                        barHeight: root.removableH
                        labelSize: root.labelSize
                        warnAt: 75
                        dangerAt: 90
                        tip: Bar.diskTip(modelData, modelData.bus === "usb" ? "USB disk" : "Card")
                        tipHost: root.tipHost
                    }
                }
            }

            // battery
            Item {
                id: battery

                readonly property var b: root.s ? root.s.battery : null
                readonly property real level: battery.b ? battery.b.level : -1
                readonly property color fill: {
                    if (!battery.b)
                        return Theme.surfaceVariantText;
                    if (battery.b.charging)
                        return Theme.primary;
                    return battery.level <= 15 ? Theme.error : (battery.level <= 30 ? Theme.warning : Theme.primary);
                }

                visible: battery.b !== null
                width: parent.width
                height: cell.height + 2 + batteryLabel.implicitHeight

                Rectangle {
                    id: nub

                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.round(cell.width * 0.4)
                    height: 2
                    radius: 1
                    color: Theme.withAlpha(Theme.surfaceText, 0.3)
                }

                Rectangle {
                    id: cell

                    anchors.top: nub.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: root.barW * 2 + 4
                    height: 26
                    radius: Math.min(5, width / 3)
                    color: Theme.withAlpha(Theme.surfaceText, 0.12)

                    Item {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: battery.level >= 0 ? Math.round(parent.height * Math.min(100, battery.level) / 100) : 0
                        clip: true

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: cell.height
                            radius: cell.radius
                            color: battery.fill
                        }
                    }

                    DC.DIcon {
                        anchors.centerIn: parent
                        visible: battery.b !== null && battery.b.charging
                        name: "bolt"
                        size: Math.round(cell.width * 0.8)
                        color: Theme.surfaceText
                        filled: true
                    }
                }

                StyledText {
                    id: batteryLabel

                    anchors.top: cell.bottom
                    anchors.topMargin: 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Bar.pctLabel(battery.level)
                    wrapMode: Text.NoWrap
                    font.pixelSize: root.labelSize
                    font.features: {
                        "tnum": 1
                    }
                    color: Theme.surfaceText
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    onEntered: root.tipHost?.showTip(battery, Bar.batteryTip(battery.b))
                    onExited: root.tipHost?.hideTip(battery)
                }
            }

            // a phone: signal | Wi-Fi or mobile data, then calls | data used
            Grid {
                visible: root.host.android
                columns: 2
                columnSpacing: root.colGap
                rowSpacing: root.groupGap

                IconCell {
                    width: root.colW
                    iconSize: root.iconS
                    icon: Bar.signalIcon(root.s ? root.s.cell : null, root.s ? root.s.airplane : false)
                    iconColor: {
                        const c = root.s ? root.s.cell : null;
                        if (!c || root.s.airplane)
                            return Theme.surfaceVariantText;
                        if (!c.inService)
                            return Theme.error;
                        return c.level <= 1 ? Theme.warning : Theme.surfaceText;
                    }
                    tip: Bar.signalTip(root.s)
                    tipHost: root.tipHost
                }

                IconCell {
                    width: root.colW
                    iconSize: root.iconS
                    icon: Bar.networkIcon(root.s)
                    iconColor: {
                        const n = root.s ? root.s.net : "";
                        if (n === "wifi")
                            return Theme.surfaceText;
                        if (n === "mobile")
                            return Theme.primary;
                        if (n === "none")
                            return Theme.error;
                        return Theme.surfaceVariantText;
                    }
                    tip: Bar.networkTip(root.s)
                    tipHost: root.tipHost
                }

                IconCell {
                    width: root.colW
                    iconSize: root.iconS
                    icon: Bar.callIcon(root.s ? root.s.call : "")
                    iconColor: {
                        const c = root.s ? root.s.call : "";
                        if (c === "ringing")
                            return Theme.warning;
                        if (c === "offhook")
                            return Theme.primary;
                        return Theme.surfaceVariantText;
                    }
                    filled: root.s !== null && root.s.call !== "idle" && root.s.call !== ""
                    pulsing: root.s !== null && root.s.call === "ringing"
                    badge: root.s && root.s.missed > 0 ? String(root.s.missed) : ""
                    tip: Bar.callTip(root.s)
                    tipHost: root.tipHost
                }

                Item {
                    width: root.colW
                    height: dataRing.height

                    Ring {
                        id: dataRing

                        readonly property var d: root.s ? root.s.data : null
                        readonly property real pct: dataRing.d ? dataRing.d.percent : -1

                        anchors.horizontalCenter: parent.horizontalCenter
                        diameter: Math.min(root.colW + 2, root.ringD)
                        value: dataRing.pct >= 0 ? dataRing.pct / 100 : -1
                        ringColor: dataRing.pct >= 100 ? Theme.error : (dataRing.pct >= 80 ? Theme.warning : Theme.primary)
                        // No limit to measure against: the gigabytes used.
                        text: dataRing.pct >= 0 ? Bar.pctLabel(dataRing.pct) : (dataRing.d ? (dataRing.d.used / 1e9).toFixed(dataRing.d.used < 1e10 ? 1 : 0) : "–")
                        textSize: root.labelSize - 1
                        contentColor: dataRing.d ? Theme.surfaceText : Theme.surfaceVariantText
                        tip: Bar.dataTip(root.s)
                        tipHost: root.tipHost
                    }
                }
            }

            // ssh | Syncthing | rsync | backups, one under the other
            Column {
                width: parent.width
                spacing: Theme.spacingXS

                Ring {
                    readonly property int n: root.s && root.s.ssh ? root.s.ssh.total : -1

                    anchors.horizontalCenter: parent.horizontalCenter
                    diameter: root.ringD
                    value: n > 0 ? 1 : -1
                    ringColor: Theme.primary
                    text: n >= 0 ? String(n) : "–"
                    textSize: root.labelSize
                    contentColor: n > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                    tip: Bar.sshTip(root.s)
                    tipHost: root.tipHost
                }

                Ring {
                    readonly property var sync: root.s ? root.s.sync : null
                    readonly property string st: sync ? sync.state : "unknown"
                    readonly property color tone: {
                        switch (st) {
                        case "working":
                        case "idle":
                            return Theme.primary;
                        case "paused":
                            return Theme.warning;
                        case "error":
                            return Theme.error;
                        default:
                            return Theme.surfaceVariantText;
                        }
                    }

                    anchors.horizontalCenter: parent.horizontalCenter
                    diameter: root.ringD
                    value: st === "idle" || st === "paused" || st === "error" ? 1 : -1
                    spinning: st === "working"
                    ringColor: tone
                    icon: Bar.syncIcon(sync)
                    iconSpins: st === "working"
                    contentColor: st === "idle" && sync && sync.failedItems > 0 ? Theme.warning : tone
                    tip: Bar.syncTip(root.s)
                    tipHost: root.tipHost
                }

                JobRing {
                    anchors.horizontalCenter: parent.horizontalCenter
                    job: root.s ? root.s.rsync : null
                    diameter: root.ringD
                    textSize: root.labelSize
                    tip: Bar.jobTip(root.s ? root.s.rsync : null, "rsync", "pair")
                    tipHost: root.tipHost
                }

                JobRing {
                    anchors.horizontalCenter: parent.horizontalCenter
                    job: root.s ? root.s.backup : null
                    diameter: root.ringD
                    textSize: root.labelSize
                    tip: Bar.jobTip(root.s ? root.s.backup : null, "Backups", "backup")
                    tipHost: root.tipHost
                }
            }
        }
    }
}
