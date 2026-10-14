import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "time.js" as Time

// One notification card. Everything renders untruncated — app name, age,
// title and body — no max-line clamp and no elide anywhere, so nothing ends
// in "…" and nothing needs expanding. StyledText elides by default, so every
// text here turns that off by hand and wraps instead, breaking inside a word
// only when one word (a URL, a path) is wider than the card. Avatar-resolution mirrors the shipped Notification Center's
// HistoryNotificationCard so icons/avatars resolve identically; a
// notification carrying a real image (as opposed to an icon-provider avatar)
// also gets a larger preview beneath the text.
Rectangle {
    id: root

    required property var item
    property bool isCurrent: false
    // The panel's clock, for the "x minutes ago" stamp. See time.js.
    property real nowMs: 0

    signal removeRequested

    readonly property string rawImage: item.image || ""
    readonly property string iconFromImage: rawImage.startsWith("image://icon/") ? rawImage.substring(13) : ""
    readonly property bool hasNotificationImage: rawImage !== "" && (!rawImage.startsWith("image://icon/") || iconFromImage.startsWith("/"))
    readonly property string resolvedImage: iconFromImage.startsWith("/") ? ("file://" + iconFromImage) : rawImage
    readonly property string resolvedAppIcon: {
        if (hasNotificationImage)
            return resolvedImage;
        const appIcon = item.appIcon || "";
        if (appIcon.startsWith("file://") || appIcon.startsWith("http://") || appIcon.startsWith("https://") || appIcon.includes("/"))
            return appIcon;
        return "";
    }

    // The app name goes into a styled line next to the age, so its own
    // markup characters must stay text.
    function escapeHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    width: parent ? parent.width : 0
    height: mainCol.implicitHeight + Theme.spacingS * 2
    radius: Theme.cornerRadius / 2
    color: hover.hovered ? Theme.surfaceHover : "transparent"
    border.color: isCurrent ? Theme.primary : "transparent"
    border.width: isCurrent ? 2 : 0

    HoverHandler {
        id: hover
    }

    Column {
        id: mainCol

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingXS
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingXS

        Row {
            id: header

            width: parent.width
            spacing: Theme.spacingS

            DankCircularImage {
                imageSource: root.resolvedAppIcon
                // The app's own themed icon when there is no image to show,
                // resolved the way the shipped history card resolves it -- most
                // apps send a theme icon name, not a path, and a fixed
                // fallback gave every one of their cards the same bell.
                fallbackIcon: NotificationService.notificationFallbackIcon(root.item.image || "", root.item.appIcon || "") || "notifications"
                width: 30
                height: 30
                anchors.verticalCenter: parent.verticalCenter
            }

            // App name and age as one wrapping line: two texts side by side
            // had to share the width, and the name was cut to make room.
            StyledText {
                width: parent.width - 30 - deleteBtn.width - Theme.spacingS * 2
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.StyledText
                text: "<font color=\"" + Theme.primary + "\">" + root.escapeHtml(item.appName || "app") + "</font>  ·  " + Time.relTime(item.timestamp, root.nowMs)
                font.pixelSize: Theme.fontSizeSmall - 2
                color: Theme.surfaceVariantText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                elide: Text.ElideNone
            }

            DankActionButton {
                id: deleteBtn

                iconName: "close"
                iconSize: 14
                anchors.verticalCenter: parent.verticalCenter
                opacity: hover.hovered ? 1 : 0
                visible: opacity > 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: 100
                    }
                }

                onClicked: root.removeRequested()
            }
        }

        StyledText {
            width: parent.width
            text: item.summary || "(no title)"
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            elide: Text.ElideNone
            visible: text.length > 0
        }

        StyledText {
            width: parent.width
            text: item.htmlBody || item.body || ""
            textFormat: Text.StyledText
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            elide: Text.ElideNone
            visible: text.length > 0
        }

        // A real photo/screenshot attachment, not just an avatar-sized icon —
        // shown at readable size instead of squeezed into the 30px header
        // circle. PreserveAspectFit rather than Crop: nothing about the
        // image gets cut off, at the cost of possible letterboxing.
        Rectangle {
            width: parent.width
            height: root.hasNotificationImage ? Math.min(220, width * 0.6) : 0
            radius: Theme.cornerRadius / 2
            color: Theme.surfaceContainerHighest
            clip: true
            visible: root.hasNotificationImage

            Image {
                anchors.fill: parent
                source: root.hasNotificationImage ? root.resolvedImage : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                smooth: true
            }
        }
    }
}
