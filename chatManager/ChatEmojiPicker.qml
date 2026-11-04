pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets
import "emoji.js" as Emoji

// Choose an emoji, to put in a message or to react with.
//
// A desktop has no emoji key, so they are found by name: type "laugh",
// "thumbs" or "heart" and the matches are there, the best one first, ready for
// Enter. With nothing typed it shows the recently used ones, and the
// categories along the top for browsing.
//
// Keys:
//   typing          searches
//   Enter           picks the highlighted emoji (the first match)
//   ↓ / Tab         into the grid, where the arrows move and Enter picks
//   Tab / Shift+Tab with nothing typed, the next / previous category
//   Esc             closes
StyledRect {
    id: root

    required property var chatCore

    property string title: I18n.tr("Emoji")

    signal picked(string emoji)
    signal cancelled

    // -1 is the recently used ones.
    property int category: -1

    readonly property var recent: root.chatCore ? root.chatCore.recentEmoji : []
    readonly property string query: search.text.trim()

    readonly property var shown: {
        if (root.query !== "")
            return Emoji.search(root.query, 120);
        if (root.category < 0)
            return root.recent;
        return Emoji.categories[root.category].emoji.map(e => e[0]);
    }

    color: Theme.withAlpha(Theme.surfaceContainer, 0.97)
    radius: Theme.cornerRadius

    // Swallow clicks so they cannot reach the conversation behind.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
    }

    onVisibleChanged: {
        if (!visible)
            return;
        search.text = "";
        root.category = root.recent.length > 0 ? -1 : 0;
        grid.currentIndex = 0;
        search.forceActiveFocus();
    }

    onShownChanged: grid.currentIndex = 0

    function pick(index) {
        const emoji = root.shown[index];
        if (!emoji)
            return;
        root.chatCore?.noteEmoji(emoji);
        root.picked(emoji);
    }

    function stepCategory(by) {
        const count = Emoji.categories.length;
        // -1 (recent) only while there is something in it.
        const first = root.recent.length > 0 ? -1 : 0;
        let next = root.category + by;
        if (next >= count)
            next = first;
        if (next < first)
            next = count - 1;
        root.category = next;
    }

    Column {
        id: body

        anchors.centerIn: parent
        width: Math.min(520, parent.width - Theme.spacingXL * 2)
        height: Math.min(460, parent.height - Theme.spacingXL * 2)
        spacing: Theme.spacingS

        Row {
            id: header
            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - closeButton.width - Theme.spacingS
                text: root.title
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            DankActionButton {
                id: closeButton
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 28
                iconName: "close"
                iconColor: Theme.surfaceVariantText
                onClicked: root.cancelled()
            }
        }

        DankTextField {
            id: search
            width: parent.width
            placeholderText: I18n.tr("Search emoji: smile, heart, thumbs up…")
            leftIconName: "search"

            onAccepted: root.pick(grid.currentIndex)
            Keys.onEscapePressed: event => {
                root.cancelled();
                event.accepted = true;
            }
            Keys.onDownPressed: event => {
                if (root.shown.length > 0)
                    grid.forceActiveFocus();
                event.accepted = true;
            }
            Keys.onTabPressed: event => {
                if (root.query === "")
                    root.stepCategory(1);
                else if (root.shown.length > 0)
                    grid.forceActiveFocus();
                event.accepted = true;
            }
            Keys.onBacktabPressed: event => {
                if (root.query === "")
                    root.stepCategory(-1);
                event.accepted = true;
            }
        }

        // The categories, for browsing. Hidden while searching, which looks
        // through all of them.
        Row {
            id: tabs
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXS
            opacity: root.query === "" ? 1 : 0.4

            Repeater {
                model: [
                    {
                        "index": -1,
                        "icon": "history",
                        "name": I18n.tr("Recently used")
                    }
                ].concat(Emoji.categories.map((c, i) => ({
                            "index": i,
                            "icon": c.icon,
                            "name": c.name
                        })))

                DankActionButton {
                    required property var modelData

                    visible: modelData.index >= 0 || root.recent.length > 0
                    buttonSize: 32
                    iconSize: Theme.fontSizeMedium + 2
                    iconName: modelData.icon
                    iconColor: root.category === modelData.index && root.query === "" ? Theme.primary : Theme.surfaceVariantText
                    backgroundColor: root.category === modelData.index && root.query === "" ? Theme.withAlpha(Theme.primary, 0.14) : "transparent"
                    tooltipText: modelData.name
                    onClicked: {
                        search.text = "";
                        root.category = modelData.index;
                        search.forceActiveFocus();
                    }
                }
            }
        }

        GridView {
            id: grid

            readonly property int columns: Math.max(1, Math.floor(width / 44))

            width: parent.width
            height: parent.height - header.height - search.height - tabs.height - hint.height - parent.spacing * 4
            cellWidth: Math.floor(width / columns)
            cellHeight: 44
            clip: true
            model: root.shown
            boundsBehavior: Flickable.StopAtBounds
            keyNavigationWraps: false
            highlightFollowsCurrentItem: true
            highlightMoveDuration: 0

            highlight: Rectangle {
                radius: Theme.cornerRadius / 2
                color: Theme.withAlpha(Theme.primary, grid.activeFocus || search.activeFocus ? 0.22 : 0.08)
            }

            delegate: Item {
                id: cell

                required property string modelData
                required property int index

                width: grid.cellWidth
                height: grid.cellHeight

                StyledText {
                    anchors.centerIn: parent
                    text: cell.modelData
                    font.pixelSize: Theme.fontSizeLarge + 6
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: grid.currentIndex = cell.index
                    onClicked: root.pick(cell.index)
                }
            }

            Keys.onReturnPressed: event => {
                root.pick(grid.currentIndex);
                event.accepted = true;
            }
            Keys.onEnterPressed: event => {
                root.pick(grid.currentIndex);
                event.accepted = true;
            }
            Keys.onEscapePressed: event => {
                root.cancelled();
                event.accepted = true;
            }
            Keys.onUpPressed: event => {
                if (grid.currentIndex < grid.columns)
                    search.forceActiveFocus();
                else
                    grid.moveCurrentIndexUp();
                event.accepted = true;
            }
            Keys.onTabPressed: event => {
                search.forceActiveFocus();
                event.accepted = true;
            }
            // Typing in the grid goes on with the search.
            Keys.onPressed: event => {
                if (event.text && event.text.length === 1 && event.text >= " " && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
                    search.text += event.text;
                    search.forceActiveFocus();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Backspace) {
                    search.text = search.text.slice(0, -1);
                    search.forceActiveFocus();
                    event.accepted = true;
                }
            }

            StyledText {
                anchors.centerIn: parent
                visible: root.shown.length === 0
                text: root.query !== "" ? I18n.tr("No emoji called “%1”").arg(root.query) : I18n.tr("Nothing used yet")
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }
        }

        StyledText {
            id: hint
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: I18n.tr("Type to search  ·  Enter to pick  ·  ↓ into the grid  ·  Tab for categories  ·  Esc to close")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }
}
