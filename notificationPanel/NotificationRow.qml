import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "time.js" as Time

// One notification card. Full title and body render untruncated — no
// max-line clamp, no elide — so everything is visible without expanding
// anything. Avatar-resolution mirrors the shipped Notification Center's
// HistoryNotificationCard so icons/avatars resolve identically; a
// notification carrying a real image (as opposed to an icon-provider avatar)
// also gets a larger preview beneath the text.
Rectangle {
    id: root

    required property var item
    property bool isCurrent: false

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
                fallbackIcon: "notifications"
                width: 30
                height: 30
                anchors.verticalCenter: parent.verticalCenter
            }

            Row {
                width: parent.width - 30 - deleteBtn.width - Theme.spacingS * 2
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    text: item.appName || "app"
                    font.pixelSize: Theme.fontSizeSmall - 2
                    color: Theme.primary
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width * 0.6)
                }

                StyledText {
                    text: "·  " + Time.relTime(item.timestamp)
                    font.pixelSize: Theme.fontSizeSmall - 2
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
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
            wrapMode: Text.WordWrap
            visible: text.length > 0
        }

        StyledText {
            width: parent.width
            text: item.htmlBody || item.body || ""
            textFormat: Text.StyledText
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
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
