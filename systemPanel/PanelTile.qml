import QtQuick
import qs.Common
import qs.Widgets

// One cell of the 3x3 grid: header strip, scrollable body, and the shared
// busy / error / empty states so every tile behaves the same way.
StyledRect {
    id: root

    default property alias content: bodyColumn.data

    property string title: ""
    property string iconName: "widgets"
    property string statusText: ""
    property color statusColor: Theme.surfaceVariantText
    property bool busy: false
    property string error: ""
    property bool empty: false
    property string emptyText: "Nothing to show"
    property string footerText: ""

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
            height: 26

            DankIcon {
                id: tileIcon

                name: root.iconName
                size: 18
                color: Theme.primary
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                anchors.left: tileIcon.right
                anchors.leftMargin: Theme.spacingS
                anchors.right: statusLabel.left
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                text: root.title
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            StyledText {
                id: statusLabel

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.statusText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.statusColor
                visible: text.length > 0
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
            height: parent.height - 26 - 1 - Theme.spacingS * 2 - (footerLabel.visible ? footerLabel.height + Theme.spacingS : 0)

            DankFlickable {
                id: flick

                anchors.fill: parent
                clip: true
                contentHeight: bodyColumn.height
                contentWidth: width
                visible: !root.busy && !root.error && !root.empty

                Column {
                    id: bodyColumn

                    width: flick.width
                    spacing: 1
                }
            }

            Item {
                anchors.fill: parent
                visible: root.busy || root.error.length > 0 || root.empty

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS
                    width: parent.width - Theme.spacingM * 2

                    DankIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: root.busy ? "hourglass_empty" : (root.error ? "error_outline" : "check_circle")
                        size: 22
                        color: root.error ? Theme.error : Theme.surfaceVariantText
                        opacity: 0.7
                    }

                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: root.busy ? "Loading…" : (root.error ? root.error : root.emptyText)
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.error ? Theme.error : Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                }
            }
        }

        StyledText {
            id: footerLabel

            width: parent.width
            text: root.footerText
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            opacity: 0.75
            elide: Text.ElideRight
            visible: text.length > 0
        }
    }
}
