import QtQuick
import qs.Common
import qs.Widgets

// WiFi / Bluetooth / Speaker: a header (icon, title, status, letter-hinted
// on/off toggle) over an always-visible, scrollable device list. Nothing
// here collapses — the letter toggles the radio/mute state directly, it
// doesn't expand or hide anything.
Rectangle {
    id: root

    property string letter: ""
    property string title: ""
    property string iconName: "widgets"
    property string statusText: ""
    property bool toggleOn: false
    property var items: []
    property string topKey: ""
    property string emptyText: "Nothing found"

    signal toggleRequested
    signal activated(var item)

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
                id: sectionIcon

                name: root.iconName
                size: 18
                color: Theme.primary
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                anchors.left: sectionIcon.right
                anchors.leftMargin: Theme.spacingS
                anchors.right: headerRight.left
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                text: root.title
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            Row {
                id: headerRight

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                StyledText {
                    text: root.statusText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text.length > 0
                }

                LetterBadge {
                    letter: root.letter
                    active: root.toggleOn
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankToggle {
                    checked: root.toggleOn
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.toggleRequested()
                }
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
            height: parent.height - 26 - 1 - Theme.spacingS * 2

            DankFlickable {
                anchors.fill: parent
                clip: true
                contentHeight: col.height
                contentWidth: width
                visible: root.items.length > 0

                Column {
                    id: col

                    width: parent.width
                    spacing: 1

                    Repeater {
                        model: root.items

                        DeviceRow {
                            required property var modelData

                            item: modelData
                            isTopMatch: modelData.key === root.topKey && root.topKey !== ""
                            onActivated: root.activated(modelData)
                        }
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                width: parent.width - Theme.spacingM * 2
                horizontalAlignment: Text.AlignHCenter
                text: root.emptyText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                visible: root.items.length === 0
            }
        }
    }
}
