import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "time.js" as Time

// One notification card. Image-resolution mirrors the shipped Notification
// Center's HistoryNotificationCard so icons/avatars resolve identically.
Rectangle {
    id: root

    required property var item

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
    height: content.implicitHeight + Theme.spacingS * 2
    radius: Theme.cornerRadius / 2
    color: hover.hovered ? Theme.surfaceHover : "transparent"

    HoverHandler {
        id: hover
    }

    Row {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingXS
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        DankCircularImage {
            imageSource: root.resolvedAppIcon
            fallbackIcon: "notifications"
            width: 30
            height: 30
            anchors.verticalCenter: parent.verticalCenter
        }

        Column {
            width: parent.width - 30 - deleteBtn.width - Theme.spacingS * 2
            spacing: 1

            Row {
                width: parent.width
                spacing: Theme.spacingXS

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

            StyledText {
                width: parent.width
                text: item.summary || "(no title)"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
                visible: text.length > 0
            }

            StyledText {
                width: parent.width
                text: item.htmlBody || item.body || ""
                textFormat: Text.StyledText
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                visible: text.length > 0
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
}
