pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Notifications
import qs.Common
import qs.Services
import qs.Widgets
import "format.js" as Fmt

// One notification, one line:
//
//     4m  [icon]  appname   Title  ->  body text that keeps going...  v
//
// The bubble is only as wide as its text until that would pass `maxWidth`
// (half the screen by default). Past that the title and body are elided and a
// chevron appears, which unfolds the same bubble into a wrapped, multi-line
// version in place.
Item {
    id: line

    required property var wrapper
    required property var host
    required property real maxWidth
    required property string align

    // The window masks its input region to these, so only the drawn bubble --
    // not the empty track beside it -- swallows clicks.
    readonly property Item hitItem: bubble

    property bool expanded: false
    property bool hovered: false

    // A held line does not count down. The daemon owns the clock, because
    // these delegates come and go as the stack changes and a timer living in
    // here would restart every time a neighbour appeared.
    readonly property bool held: line.hovered || line.expanded

    // Which notification this line is currently holding, if any. Rows are
    // indexed, so `wrapper` can be swapped under a hovered line when an older
    // one expires -- the hold has to move with it rather than stay stuck on a
    // notification that is no longer here.
    property var holdTarget: null

    function syncHold() {
        if (!line.host)
            return;
        const want = line.held ? line.wrapper : null;
        if (want === line.holdTarget)
            return;
        if (line.holdTarget)
            line.host.hold(line.holdTarget, false);
        line.holdTarget = want;
        if (want)
            line.host.hold(want, true);
    }

    onHeldChanged: syncHold()
    onWrapperChanged: {
        // A recycled row must not inherit the previous notification's
        // unfolded state.
        line.expanded = false;
        syncHold();
    }

    Component.onDestruction: {
        if (line.holdTarget && line.host)
            line.host.hold(line.holdTarget, false);
    }

    readonly property bool isCritical: wrapper ? wrapper.urgency === NotificationUrgency.Critical : false
    readonly property color accent: isCritical ? Theme.error : Theme.primary

    readonly property real fontSize: host.fontSize
    readonly property real iconSize: Math.round(fontSize * 1.4)
    readonly property real hPad: Math.round(fontSize * 0.6)
    readonly property real vPad: Math.round(fontSize * 0.3)
    readonly property real gap: Math.round(fontSize * 0.45)

    // The age stamp has to re-read the clock on its own; NotificationService's
    // own tick only fires every 30s and only while it holds wrappers.
    property bool ageTick: false
    readonly property string ageText: {
        line.ageTick;
        NotificationService.timeUpdateTick;
        return line.wrapper ? Fmt.compactAge(line.wrapper.time) : "";
    }

    Timer {
        interval: 10000
        running: true
        repeat: true
        onTriggered: line.ageTick = !line.ageTick
    }

    readonly property string appName: line.wrapper ? Fmt.appLabel(line.wrapper.appName) : ""
    readonly property string title: line.wrapper ? Fmt.oneLine(line.wrapper.summary) : ""
    readonly property string bodyPlain: line.wrapper ? Fmt.oneLine(line.wrapper.body) : ""
    readonly property string bodyRich: line.wrapper ? (line.wrapper.htmlBody || line.wrapper.body || "") : ""
    readonly property var actions: line.wrapper ? line.wrapper.actions : []

    readonly property bool hasTime: host.showTime && ageText.length > 0
    readonly property bool hasIcon: host.showIcon
    readonly property bool hasApp: host.showAppName && appName.length > 0
    readonly property bool hasTitle: title.length > 0
    readonly property bool hasBody: bodyPlain.length > 0
    readonly property bool hasArrow: hasTitle && hasBody

    // --- width budget ----------------------------------------------------
    //
    // Everything is measured off TextMetrics rather than off the laid-out
    // items, so the bubble's width never depends on a width that depends on
    // the bubble.

    // TextMetrics reports the advance width; Text lays out a hair wider and
    // would then elide a line that was measured as fitting exactly.
    readonly property real slack: 2

    readonly property real timeW: hasTime ? timeMetrics.width + slack : 0
    readonly property real iconW: hasIcon ? iconSize : 0
    readonly property real appW: hasApp ? Math.min(appMetrics.width + slack, maxWidth * 0.3) : 0
    readonly property real arrowW: hasArrow ? arrowMetrics.width + slack : 0
    readonly property real titleNat: hasTitle ? titleMetrics.width + slack : 0
    readonly property real bodyNat: hasBody ? bodyMetrics.width + slack : 0

    readonly property int partCount: (hasTime ? 1 : 0) + (hasIcon ? 1 : 0) + (hasApp ? 1 : 0) + (hasArrow ? 1 : 0) + (hasTitle ? 1 : 0) + (hasBody ? 1 : 0)
    readonly property real gapsW: gap * Math.max(0, partCount - 1)
    readonly property real naturalWidth: hPad * 2 + timeW + iconW + appW + arrowW + titleNat + bodyNat + gapsW
    readonly property bool truncated: naturalWidth > maxWidth
    readonly property real chevronReserve: (truncated || expanded) ? iconSize + gap : 0

    // What is left for the two elastic fields once the fixed furniture is paid
    // for. The body keeps at least half of it, because a title without its
    // body is the less useful half of a notification.
    readonly property real flexAvail: Math.max(0, maxWidth - (hPad * 2 + timeW + iconW + appW + arrowW + gapsW + chevronReserve))
    readonly property real titleW: truncated ? Math.min(titleNat, Math.max(0, flexAvail - Math.min(bodyNat, flexAvail * 0.5))) : titleNat
    readonly property real bodyW: truncated ? Math.max(0, flexAvail - titleW) : bodyNat

    // Expanded, the header keeps only the furniture and the full title.
    readonly property real headerFlex: Math.max(0, maxWidth - (hPad * 2 + timeW + iconW + appW + gapsW + iconSize + gap))

    height: bubble.height
    visible: line.wrapper !== null

    Component.onCompleted: enterAnim.start()

    ParallelAnimation {
        id: enterAnim

        NumberAnimation {
            target: line
            property: "opacity"
            from: 0
            to: 1
            duration: Theme.shortDuration
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: slide
            property: "amount"
            from: line.align === "left" ? -24 : 24
            to: 0
            duration: Theme.mediumDuration
            easing.type: Easing.OutCubic
        }
    }

    // Reading a long notification should not race its own expiry, which
    // `held` takes care of.
    function toggleExpand() {
        line.expanded = !line.expanded;
    }

    TextMetrics {
        id: timeMetrics

        font: timeText.font
        text: line.ageText
    }

    TextMetrics {
        id: appMetrics

        font: appText.font
        text: line.appName
    }

    TextMetrics {
        id: titleMetrics

        font: titleText.font
        text: line.title
    }

    TextMetrics {
        id: bodyMetrics

        font: bodyText.font
        text: line.bodyPlain
    }

    TextMetrics {
        id: arrowMetrics

        font: arrowText.font
        text: arrowText.text
    }

    Rectangle {
        id: bubble

        readonly property color base: line.hovered ? Theme.surfaceContainerHigh : Theme.surfaceContainer

        anchors.right: line.align === "right" ? parent.right : undefined
        anchors.left: line.align === "left" ? parent.left : undefined
        anchors.horizontalCenter: line.align === "center" ? parent.horizontalCenter : undefined

        width: line.expanded ? line.maxWidth : Math.min(line.naturalWidth, line.maxWidth)
        height: content.implicitHeight + line.vPad * 2
        radius: Theme.cornerRadius / 2
        color: Qt.rgba(base.r, base.g, base.b, Math.max(0.05, line.host.backgroundOpacity / 100))
        border.width: line.isCritical ? 1 : 0
        border.color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.6)

        transform: Translate {
            id: slide

            property real amount: 0

            x: slide.amount
        }

        Behavior on width {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Easing.OutCubic
            }
        }

        Behavior on height {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Easing.OutCubic
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

            onEntered: line.hovered = true
            onExited: line.hovered = false
            onClicked: mouse => {
                if (!line.wrapper)
                    return;
                if (mouse.button === Qt.RightButton) {
                    line.toggleExpand();
                    return;
                }
                if (mouse.button === Qt.MiddleButton) {
                    NotificationService.dismissNotification(line.wrapper);
                    return;
                }
                if (line.actions && line.actions.length > 0) {
                    line.actions[0].invoke();
                    NotificationService.dismissNotification(line.wrapper);
                    return;
                }
                line.host.retire(line.wrapper);
            }
        }

        Item {
            id: chevron

            anchors.right: parent.right
            anchors.rightMargin: line.hPad
            y: content.y
            width: line.iconSize
            height: head.height
            visible: line.truncated || line.expanded

            DankIcon {
                anchors.centerIn: parent
                name: line.expanded ? "keyboard_arrow_up" : "keyboard_arrow_down"
                size: line.iconSize
                color: line.hovered ? Theme.surfaceText : Theme.surfaceVariantText
            }

            MouseArea {
                anchors.fill: parent
                onClicked: line.toggleExpand()
            }
        }

        Column {
            id: content

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: line.hPad
            // chevronReserve is already part of the width budget, so reserving
            // it here keeps the unfold arrow pinned to the right edge instead
            // of trailing the text.
            anchors.rightMargin: line.hPad + line.chevronReserve
            anchors.topMargin: line.vPad

            spacing: line.vPad

            Row {
                id: head

                width: parent.width
                spacing: line.gap

                StyledText {
                    id: timeText

                    anchors.verticalCenter: parent.verticalCenter
                    visible: line.hasTime
                    text: line.ageText
                    font.pixelSize: line.fontSize - 2
                    color: Theme.surfaceVariantText
                    opacity: 0.7
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                }

                DankCircularImage {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: line.hasIcon
                    width: line.iconSize
                    height: line.iconSize
                    cacheImages: false
                    imageSource: line.wrapper?.displayImage ?? ""
                    hasImage: line.wrapper?.hasDisplayImage ?? false
                    fallbackIcon: line.wrapper?.fallbackIconName ?? "notifications"
                    fallbackText: line.appName.charAt(0).toUpperCase()
                }

                StyledText {
                    id: appText

                    anchors.verticalCenter: parent.verticalCenter
                    visible: line.hasApp
                    width: line.appW
                    text: line.appName
                    font.pixelSize: line.fontSize
                    font.weight: Font.DemiBold
                    color: line.accent
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }

                StyledText {
                    id: titleText

                    anchors.verticalCenter: parent.verticalCenter
                    visible: line.hasTitle
                    width: line.expanded ? Math.min(line.titleNat, line.headerFlex) : line.titleW
                    text: line.title
                    font.pixelSize: line.fontSize
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }

                StyledText {
                    id: arrowText

                    anchors.verticalCenter: parent.verticalCenter
                    visible: line.hasArrow && !line.expanded
                    text: "→"
                    font.pixelSize: line.fontSize
                    color: Theme.outline
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                }

                StyledText {
                    id: bodyText

                    anchors.verticalCenter: parent.verticalCenter
                    visible: line.hasBody && !line.expanded
                    width: line.bodyW
                    text: line.bodyPlain
                    font.pixelSize: line.fontSize
                    color: Theme.surfaceVariantText
                    // The whole point of the collapsed line: one line, ever.
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }
            }

            StyledText {
                id: wrappedBody

                width: parent.width
                visible: line.expanded && line.hasBody
                text: line.bodyRich
                textFormat: Text.StyledText
                font.pixelSize: line.fontSize
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                maximumLineCount: line.host.expandedMaxLines
                elide: Text.ElideRight
            }

            Flow {
                width: parent.width
                visible: line.expanded && line.actions && line.actions.length > 0
                spacing: line.gap

                Repeater {
                    model: line.expanded ? line.actions : []

                    delegate: Rectangle {
                        required property var modelData

                        width: actionLabel.implicitWidth + line.hPad * 2
                        height: line.fontSize * 1.8
                        radius: height / 2
                        color: actionHover.containsMouse ? Theme.surfaceContainerHighest : "transparent"
                        border.width: 1
                        border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.4)

                        StyledText {
                            id: actionLabel

                            anchors.centerIn: parent
                            text: modelData.text || modelData.identifier || "action"
                            font.pixelSize: line.fontSize - 1
                            color: line.accent
                        }

                        MouseArea {
                            id: actionHover

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                modelData.invoke();
                                NotificationService.dismissNotification(line.wrapper);
                            }
                        }
                    }
                }
            }
        }
    }
}
