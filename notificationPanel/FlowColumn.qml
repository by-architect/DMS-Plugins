import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// The full-height column on the right: every notification, newest first,
// narrowed only by the search bar (no category filter applies here).
Rectangle {
    id: root

    required property var items
    required property string emptyReason

    radius: Theme.cornerRadius
    color: Theme.floatingWindowNestedSurface
    border.color: Theme.outlineMedium
    border.width: Theme.layerOutlineWidth
    clip: true

    Column {
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingS

        Item {
            width: parent.width
            height: 22

            DankIcon {
                id: flowIcon

                name: "notifications"
                size: 18
                color: Theme.primary
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                anchors.left: flowIcon.right
                anchors.leftMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                text: "Flow"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.items.length
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.outlineVariant
            opacity: 0.5
        }

        Item {
            width: parent.width
            height: parent.height - 18 - 1 - Theme.spacingS * 2

            DankFlickable {
                anchors.fill: parent
                clip: true
                contentHeight: flowCol.height
                contentWidth: width
                visible: root.items.length > 0

                Column {
                    id: flowCol

                    width: parent.width
                    spacing: 1

                    Repeater {
                        model: root.items

                        NotificationRow {
                            required property var modelData

                            item: modelData
                            onRemoveRequested: NotificationService.removeFromHistory(modelData.id)
                        }
                    }
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingS
                width: parent.width - Theme.spacingM * 2
                visible: root.items.length === 0

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "notifications_off"
                    size: 24
                    color: Theme.surfaceVariantText
                    opacity: 0.6
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.emptyReason
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
