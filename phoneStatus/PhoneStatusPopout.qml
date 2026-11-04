pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "phone.js" as Phone

// Everything about the phone, top to bottom: what its status bar shows, the
// mobile data used this cycle, what is playing, the notifications waiting on
// it, and its newest photos. Past a height it scrolls rather than growing off
// the screen.
PopoutComponent {
    id: popout

    readonly property var S: PhoneStatusService
    readonly property var r: S.result
    readonly property int maxBodyHeight: 680

    property real nowMs: Date.now()
    property bool showOngoing: false

    Component.onCompleted: PhoneStatusService.popouts++
    Component.onDestruction: PhoneStatusService.popouts = Math.max(0, PhoneStatusService.popouts - 1)

    headerText: S.phoneName || "Phone"
    detailsText: {
        if (!S.host)
            return "No phone picked yet";
        const parts = [];
        if (popout.r) {
            const p = popout.r.props;
            if (p.model)
                parts.push(p.model);
            if (p.android)
                parts.push("Android " + p.android);
        }
        if (S.checking)
            parts.push("checking…");
        else if (S.checkedMs > 0)
            parts.push((S.online ? "checked " : "last seen ") + Phone.agoText(S.online ? S.checkedMs : S.onlineMs, popout.nowMs));
        return parts.join(" · ");
    }

    headerActions: Component {
        Row {
            spacing: 2

            DankActionButton {
                visible: PhoneStatusService.online && PhoneStatusService.result.hasMpv
                iconName: PhoneStatusService.ringing ? "notifications_active" : "ring_volume"
                buttonSize: 32
                iconColor: PhoneStatusService.ringing ? Theme.primary : Theme.surfaceVariantText
                tooltipText: "Ring it for 15 seconds, at full volume"
                onClicked: PhoneStatusService.ring()
            }

            DankActionButton {
                visible: PhoneStatusService.online && PhoneStatusService.result.root
                iconName: "lock"
                buttonSize: 32
                iconColor: Theme.surfaceVariantText
                tooltipText: "Lock it"
                onClicked: PhoneStatusService.lock()
            }

            DankActionButton {
                visible: PhoneStatusService.host !== null
                iconName: "terminal"
                buttonSize: 32
                iconColor: Theme.surfaceVariantText
                tooltipText: "Open an ssh session"
                onClicked: PhoneStatusService.openSession()
            }

            DankActionButton {
                visible: PhoneStatusService.host !== null
                iconName: "refresh"
                buttonSize: 32
                iconColor: Theme.surfaceVariantText
                tooltipText: "Check now"
                onClicked: PhoneStatusService.refresh(true)
            }
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: popout.nowMs = Date.now()
    }

    // ---- small pieces -------------------------------------------------

    component Card: StyledRect {
        default property alias content: inner.data
        property string title: ""

        width: parent ? parent.width : 0
        implicitHeight: inner.implicitHeight + Theme.spacingM * 2
        height: implicitHeight
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: inner

            x: Theme.spacingM
            y: Theme.spacingM
            width: parent.width - Theme.spacingM * 2
            spacing: Theme.spacingS
        }
    }

    component CardTitle: StyledText {
        width: parent ? parent.width : 0
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
        elide: Text.ElideRight
    }

    // icon, label, value -- one line of the status card.
    component InfoRow: Item {
        property string icon: ""
        property string label: ""
        property string value: ""
        property color valueColor: Theme.surfaceText

        width: parent ? parent.width : 0
        implicitHeight: Math.max(rowIcon.height, valueLabel.implicitHeight)
        height: implicitHeight

        DankIcon {
            id: rowIcon

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: parent.icon
            size: Theme.iconSize - 4
            color: Theme.surfaceVariantText
        }

        StyledText {
            id: rowLabel

            anchors.left: rowIcon.right
            anchors.leftMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            width: 84
            text: parent.label
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            id: valueLabel

            anchors.left: rowLabel.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: parent.value
            font.pixelSize: Theme.fontSizeSmall
            color: parent.valueColor
            elide: Text.ElideRight
        }
    }

    component Bar: Rectangle {
        property real fraction: 0
        property color fill: fraction >= 1 ? Theme.error : (fraction >= 0.8 ? Theme.warning : Theme.primary)

        width: parent ? parent.width : 0
        height: 6
        radius: 3
        color: Theme.surfaceContainerHighest

        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, parent.fraction))
            height: parent.height
            radius: parent.radius
            color: parent.fill
            visible: parent.fraction > 0
        }
    }

    // ---- the body -----------------------------------------------------

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

                // Not set up, not reachable, or no root: say so first.
                Card {
                    visible: !popout.S.host || (!popout.S.online && popout.S.state !== "") || (popout.r !== null && !popout.r.root)

                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: popout.S.host && popout.S.online ? Theme.surfaceVariantText : Theme.warning
                        text: {
                            const S = popout.S;
                            if (!S.host)
                                return "Pick the phone under Settings → Plugins → Phone Status. It has to be in SSH Hosts first: Termux's sshd (port 8022 unless you changed it), with a key.";
                            if (!S.online)
                                return S.phoneName + " is " + (S.state === "unreachable" ? "not reachable" : "not answering") + (S.detail ? ": " + S.detail : "") + (popout.r ? ". What is below is from " + Phone.agoText(S.onlineMs, popout.nowMs) + "." : "");
                            return "Termux has no root on " + S.phoneName + ", so only the battery is shown. Allow it su in Magisk (or the ROM's root settings) to see the rest.";
                        }
                    }
                }

                // ---- what the status bar shows
                Card {
                    visible: popout.r !== null

                    InfoRow {
                        readonly property var b: popout.r ? popout.r.battery : null
                        visible: b !== null
                        icon: Phone.batteryIcon(b)
                        label: "Battery"
                        valueColor: b && b.level <= 15 && b.state !== "charging" ? Theme.error : Theme.surfaceText
                        value: {
                            if (!b)
                                return "";
                            const parts = [b.level + "%"];
                            if (b.state)
                                parts.push(b.state + (b.plugged && b.state !== "on battery" ? " (" + b.plugged + ")" : ""));
                            if (isFinite(b.tempC))
                                parts.push(b.tempC.toFixed(1) + " °C");
                            if (isFinite(b.wear))
                                parts.push(b.wear + "% of new capacity");
                            return parts.join(" · ");
                        }
                    }

                    InfoRow {
                        readonly property var c: popout.r ? popout.r.cell : null
                        readonly property bool airplane: popout.r !== null && popout.r.settings.airplane === "1"
                        visible: c !== null || airplane
                        icon: Phone.signalIcon(c, airplane)
                        label: "Signal"
                        value: {
                            if (airplane)
                                return "airplane mode";
                            if (!c)
                                return "";
                            if (c.noSim)
                                return "no SIM";
                            if (!c.inService)
                                return (c.operator ? c.operator + " · " : "") + "no service";
                            const parts = [c.operator, c.rat, Phone.signalWords(c.level) + (isFinite(c.dbm) ? " (" + c.dbm + " dBm)" : "")];
                            if (c.roaming)
                                parts.push("roaming");
                            return parts.filter(x => x).join(" · ");
                        }
                    }

                    InfoRow {
                        readonly property var c: popout.r ? popout.r.cell : null
                        visible: c !== null && c.inService
                        icon: c && c.dataConnected ? "swap_vert" : "mobiledata_off"
                        label: "Mobile data"
                        value: c && c.dataConnected ? "connected" : "off"
                    }

                    InfoRow {
                        readonly property var w: popout.r ? popout.r.wifi : null
                        visible: w !== null
                        icon: w && w.connected ? "wifi" : "wifi_off"
                        label: "Wi-Fi"
                        value: !w ? "" : (w.connected ? w.ssid + (isFinite(w.rssi) ? " (" + w.rssi + " dBm)" : "") : (w.enabled ? "on, not connected" : "off"))
                    }

                    InfoRow {
                        readonly property var h: popout.r ? popout.r.hotspot : null
                        visible: h !== null
                        icon: h && h.on ? "wifi_tethering" : "portable_wifi_off"
                        label: "Hotspot"
                        value: !h ? "" : (h.on ? "on · " + (h.clients === 1 ? "1 device" : h.clients + " devices") : "off")
                    }

                    InfoRow {
                        readonly property var st: popout.r ? popout.r.settings : ({})
                        visible: popout.r !== null && popout.r.root
                        icon: st.zen && st.zen !== "0" ? "do_not_disturb_on" : (st.ringer === "0" ? "volume_off" : (st.ringer === "1" ? "vibration" : "volume_up"))
                        label: "Sound"
                        value: {
                            const ring = st.ringer === "0" ? "silent" : (st.ringer === "1" ? "vibrate" : "ring");
                            return st.zen && st.zen !== "0" ? ring + " · Do Not Disturb" : ring;
                        }
                    }

                    InfoRow {
                        readonly property var s: popout.r ? popout.r.storage : null
                        visible: s !== null
                        icon: "sd_storage"
                        label: "Storage"
                        valueColor: s && s.fraction >= 0.9 ? Theme.error : Theme.surfaceText
                        value: s ? Phone.bytesText(s.used) + " of " + Phone.bytesText(s.total) + " used" : ""
                    }

                    InfoRow {
                        visible: popout.r !== null && isFinite(popout.r.uptimeSec)
                        icon: "schedule"
                        label: "Up for"
                        value: popout.r ? Phone.uptimeText(popout.r.uptimeSec) : ""
                    }
                }

                // ---- mobile data, by Android's own counter
                Card {
                    id: dataCard

                    readonly property var d: popout.r ? popout.r.data : null
                    readonly property real cap: d ? (d.limitBytes > 0 ? d.limitBytes : d.warningBytes) : 0
                    readonly property real peak: {
                        let m = 0;
                        if (d)
                            for (const x of d.days)
                                m = Math.max(m, x.bytes);
                        return m;
                    }

                    // The day under the mouse, told in the line below the bars.
                    property int hoverDay: -1

                    visible: d !== null

                    CardTitle {
                        text: "Mobile data"
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            anchors.baseline: since.baseline
                            text: dataCard.d ? Phone.bytesText(dataCard.d.used) : ""
                            font.pixelSize: Theme.fontSizeXLarge
                            font.weight: Font.Bold
                            color: dataCard.d && dataCard.d.limitBytes > 0 && dataCard.d.used >= dataCard.d.limitBytes ? Theme.error : Theme.surfaceText
                        }

                        StyledText {
                            id: since

                            text: dataCard.d ? "used since " + Phone.dayText(dataCard.d.start) + (dataCard.d.fromPolicy ? "" : " (no data plan set on the phone: this month)") : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    Bar {
                        visible: dataCard.cap > 0
                        fraction: dataCard.cap > 0 && dataCard.d ? dataCard.d.used / dataCard.cap : 0
                    }

                    // One bar per day of the cycle so far.
                    Row {
                        width: parent.width
                        height: 36
                        spacing: 2
                        visible: dataCard.d !== null && dataCard.d.days.length > 0

                        Repeater {
                            model: dataCard.d ? dataCard.d.days : []

                            Item {
                                id: dayBar

                                required property var modelData
                                required property int index

                                width: Math.max(2, (parent.width - 2 * ((dataCard.d ? dataCard.d.days.length : 1) - 1)) / (dataCard.d ? dataCard.d.days.length : 1))
                                height: parent.height

                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    width: parent.width
                                    height: Math.max(1, parent.height * (dataCard.peak > 0 ? dayBar.modelData.bytes / dataCard.peak : 0))
                                    radius: 1
                                    color: dataCard.d && dayBar.index === dataCard.d.days.length - 1 ? Theme.primary : Theme.withAlpha(Theme.primary, 0.45)
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onContainsMouseChanged: dataCard.hoverDay = containsMouse ? dayBar.index : (dataCard.hoverDay === dayBar.index ? -1 : dataCard.hoverDay)
                                }
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        text: {
                            const d = dataCard.d;
                            if (!d)
                                return "";
                            const day = d.days[dataCard.hoverDay];
                            if (day)
                                return Phone.dayText(day.day) + ": " + Phone.bytesText(day.bytes);
                            const parts = ["today " + Phone.bytesText(d.today)];
                            if (d.limitBytes > 0)
                                parts.push("limit " + Phone.bytesText(d.limitBytes));
                            if (d.warningBytes > 0)
                                parts.push("warning at " + Phone.bytesText(d.warningBytes));
                            parts.push("new cycle " + Phone.dayText(d.end));
                            return parts.join(" · ");
                        }
                    }
                }

                // ---- now playing
                Card {
                    id: mediaCard

                    readonly property var m: popout.r ? popout.r.media : null

                    visible: m !== null

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: mediaCard.m && mediaCard.m.playing ? "play_circle" : "pause_circle"
                            size: Theme.iconSize + 6
                            color: Theme.primary
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - Theme.iconSize - 6 - Theme.spacingM

                            StyledText {
                                width: parent.width
                                text: mediaCard.m ? mediaCard.m.title : ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                width: parent.width
                                text: mediaCard.m ? [mediaCard.m.artist, mediaCard.m.app + (mediaCard.m.playing ? "" : " · paused")].filter(x => x).join(" · ") : ""
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                // ---- notifications
                Card {
                    visible: popout.r !== null && popout.r.root

                    CardTitle {
                        text: popout.S.notifications.length === 0 ? "No notifications" : (popout.S.notifications.length === 1 ? "1 notification" : popout.S.notifications.length + " notifications")
                    }

                    Repeater {
                        model: popout.S.notifications.concat(popout.showOngoing ? popout.S.ongoing : [])

                        Row {
                            id: note

                            required property var modelData

                            width: parent.width
                            spacing: Theme.spacingS
                            opacity: modelData.ongoing ? 0.7 : 1

                            StyledText {
                                width: 28
                                text: Phone.shortAge(note.modelData.when, popout.nowMs)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            Column {
                                width: parent.width - 28 - Theme.spacingS

                                StyledText {
                                    width: parent.width
                                    text: note.modelData.app + (note.modelData.title ? "  " + note.modelData.title : "")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    visible: text !== ""
                                    text: note.modelData.text
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }

                    // Running services and the like, folded away.
                    StyledText {
                        visible: popout.S.ongoing.length > 0
                        width: parent.width
                        text: (popout.showOngoing ? "Hide " : "Show ") + popout.S.ongoing.length + " ongoing (" + Array.from(new Set(popout.S.ongoing.map(n => n.app))).join(", ") + ")"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.primary
                        elide: Text.ElideRight

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: popout.showOngoing = !popout.showOngoing
                        }
                    }
                }

                // ---- newest photos
                Card {
                    id: photoCard

                    readonly property var paths: popout.r && popout.S.showPhotos ? popout.r.photos : []

                    visible: paths.length > 0

                    CardTitle {
                        text: "Newest photos"
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: photoCard.paths

                            StyledRect {
                                id: thumb

                                required property string modelData
                                readonly property string local: popout.S.photoFiles[modelData] || ""

                                width: (parent.width - Theme.spacingS * 3) / 4
                                height: width
                                radius: Theme.cornerRadius / 2
                                color: Theme.surfaceContainerHighest
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    visible: thumb.local !== ""
                                    source: thumb.local ? "file://" + thumb.local : ""
                                    sourceSize.width: 240
                                    sourceSize.height: 240
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }

                                DankIcon {
                                    anchors.centerIn: parent
                                    visible: thumb.local === ""
                                    name: "image"
                                    size: Theme.iconSize
                                    color: Theme.surfaceVariantText
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: thumb.local ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (thumb.local)
                                        Qt.openUrlExternally("file://" + thumb.local)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
