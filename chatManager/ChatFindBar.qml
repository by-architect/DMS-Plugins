pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// Finding a message in the open conversation: Ctrl+Shift+F.
//
// A bar over the top of the messages, and under it what matched, newest
// first. Choosing one -- Enter, or a click -- takes the conversation to it and
// selects it, and the bar stays, so the rest can be gone through from there:
// Up for an older match and Down for a newer one, or the arrows on the bar.
// Escape closes it, and the message found stays selected for Ctrl+R and the
// rest.
//
// What is searched is everything this device has kept of the conversation,
// not only what is loaded on screen; a match further back is paged in on the
// way to it.
Item {
    id: root

    required property var chatCore

    // A match was chosen: the conversation goes to it.
    signal hitChosen(var hit)
    signal closed

    // The conversation these matches are from, as "<provider> <chatId>". A
    // search does not follow the conversation changing; it is closed instead.
    property string chatKey: ""

    property var hits: []
    // The match the conversation was last taken to, or -1.
    property int current: -1
    // The row the keyboard is on while the list is open.
    property int highlighted: 0
    // Whether the list of matches is showing. Typing opens it; choosing one
    // puts it away, leaving the bar to step through the rest.
    property bool listOpen: false
    property bool busy: false
    property string _asked: ""

    // The fewest characters worth searching for: one letter matches nearly
    // every message.
    readonly property int minQuery: 2
    readonly property int maxHits: 200

    readonly property string query: field.text.trim()

    function focusField() {
        root.chatKey = root.chatCore.activeProvider + " " + root.chatCore.activeChatId;
        field.forceActiveFocus();
        field.selectAll();
    }

    function reset() {
        searchDebounce.stop();
        field.text = "";
        root.hits = [];
        root.current = -1;
        root.highlighted = 0;
        root.listOpen = false;
        root.busy = false;
        root._asked = "";
        root.chatKey = "";
    }

    function run() {
        const query = root.query;
        root._asked = query;
        if (query.length < root.minQuery) {
            root.hits = [];
            root.current = -1;
            root.listOpen = false;
            root.busy = false;
            return;
        }
        root.busy = true;
        const provider = root.chatCore.activeProvider;
        const chatId = root.chatCore.activeChatId;
        root.chatKey = provider + " " + chatId;
        root.chatCore.searchChat(provider, chatId, query, hits => {
            // A newer search is on its way, or the conversation has changed.
            if (query !== root._asked || root.chatKey !== provider + " " + chatId)
                return;
            root.busy = false;
            root.hits = hits;
            root.current = -1;
            root.highlighted = 0;
            root.listOpen = hits.length > 0;
        });
    }

    function choose(index) {
        if (index < 0 || index >= root.hits.length)
            return;
        root.current = index;
        root.highlighted = index;
        root.listOpen = false;
        root.hitChosen(root.hits[index]);
    }

    // step goes to the next match older or newer than the one shown. The
    // matches are newest first, so older is further down the list.
    function step(older) {
        const count = root.hits.length;
        if (count === 0)
            return;
        if (root.listOpen) {
            root.highlighted = Math.max(0, Math.min(count - 1, root.highlighted + (older ? 1 : -1)));
            resultsList.positionViewAtIndex(root.highlighted, ListView.Contain);
            return;
        }
        let next;
        if (root.current < 0)
            next = older ? 0 : count - 1;
        else
            next = root.current + (older ? 1 : -1);
        if (next >= 0 && next < count)
            root.choose(next);
    }

    // Enter takes the conversation to the match the keyboard is on; with the
    // list put away, to the next one back in time, and Shift+Enter forward
    // again. Typed faster than the search, it searches now.
    function _onReturn(event) {
        event.accepted = true;
        if (searchDebounce.running) {
            searchDebounce.stop();
            root.run();
            return;
        }
        if (root.listOpen) {
            root.choose(root.highlighted);
            return;
        }
        root.step(!(event.modifiers & Qt.ShiftModifier));
    }

    // What the counter on the bar says.
    readonly property string countText: {
        if (root.busy)
            return "";
        if (root.query.length < root.minQuery)
            return "";
        if (root.hits.length === 0)
            return I18n.tr("No matches");
        const total = root.hits.length >= root.maxHits ? root.maxHits + "+" : String(root.hits.length);
        if (root.current >= 0)
            return I18n.tr("%1 of %2").arg(root.current + 1).arg(total);
        return I18n.tr("%1 found").arg(total);
    }

    function formatWhen(timestamp) {
        if (!timestamp)
            return "";
        const date = new Date(timestamp);
        const now = new Date();
        const time = SettingsData.use24HourClock ? date.toLocaleTimeString(Qt.locale(), "HH:mm") : date.toLocaleTimeString(Qt.locale(), "h:mm AP");
        if (date.toDateString() === now.toDateString())
            return time;
        if (date.getFullYear() === now.getFullYear())
            return date.toLocaleDateString(Qt.locale(), "d MMM") + "  " + time;
        return date.toLocaleDateString(Qt.locale(), "d MMM yyyy");
    }

    function _escape(value) {
        return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    // snippet is a match's text without its formatting, around the first
    // place it matches, with the match drawn in the accent. Every character of
    // it escaped first: it is somebody else's message.
    function snippet(hit) {
        const plain = root.chatCore.previewText(hit.text || "", hit.provider || "") || hit.fileName || "";
        const lower = plain.toLowerCase();
        const at = lower.indexOf(root._asked.toLowerCase());
        if (at < 0 || root._asked === "")
            return root._escape(plain.length > 160 ? plain.slice(0, 160) + "…" : plain);
        const from = Math.max(0, at - 50);
        const to = Math.min(plain.length, at + root._asked.length + 110);
        return (from > 0 ? "…" : "") + root._escape(plain.slice(from, at)) + "<b><font color=\"" + Theme.primary + "\">" + root._escape(plain.slice(at, at + root._asked.length)) + "</font></b>" + root._escape(plain.slice(at + root._asked.length, to)) + (to < plain.length ? "…" : "");
    }

    Timer {
        id: searchDebounce
        interval: 220
        onTriggered: root.run()
    }

    // ------------------------------------------------------------ the bar

    StyledRect {
        id: bar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Theme.spacingS
        height: barRow.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.color: Theme.withAlpha(Theme.outline, 0.3)
        border.width: 1

        // Clicks on the bar stay on the bar.
        MouseArea {
            anchors.fill: parent
        }

        Row {
            id: barRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingXS
            spacing: Theme.spacingXS

            DankTextField {
                id: field
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - countLabel.width - spinner.width - 28 * 3 - parent.spacing * 5
                placeholderText: I18n.tr("Find in this conversation")
                leftIconName: "search"
                showClearButton: true

                onTextChanged: {
                    root.listOpen = false;
                    searchDebounce.restart();
                }

                Keys.onReturnPressed: event => root._onReturn(event)
                Keys.onEnterPressed: event => root._onReturn(event)

                // Up is older: up the list of matches is newer, but once one
                // has been chosen, up is where older messages are.
                Keys.onUpPressed: event => {
                    event.accepted = true;
                    root.step(!root.listOpen);
                }
                Keys.onDownPressed: event => {
                    event.accepted = true;
                    root.step(root.listOpen);
                }
                Keys.onEscapePressed: event => {
                    event.accepted = true;
                    if (root.listOpen && root.current >= 0) {
                        root.listOpen = false;
                        return;
                    }
                    root.closed();
                }
            }

            DankSpinner {
                id: spinner
                anchors.verticalCenter: parent.verticalCenter
                width: root.busy ? 18 : 0
                height: 18
                visible: root.busy
            }

            StyledText {
                id: countLabel
                anchors.verticalCenter: parent.verticalCenter
                text: root.countText
                font.pixelSize: Theme.fontSizeSmall
                color: root.hits.length === 0 ? Theme.surfaceVariantText : Theme.surfaceText
            }

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 28
                iconSize: Theme.fontSizeLarge
                iconName: "keyboard_arrow_up"
                iconColor: Theme.surfaceVariantText
                enabled: root.hits.length > 0
                tooltipText: I18n.tr("Older match (↑)")
                onClicked: {
                    root.listOpen = false;
                    root.step(true);
                }
            }

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 28
                iconSize: Theme.fontSizeLarge
                iconName: "keyboard_arrow_down"
                iconColor: Theme.surfaceVariantText
                enabled: root.hits.length > 0
                tooltipText: I18n.tr("Newer match (↓)")
                onClicked: {
                    root.listOpen = false;
                    root.step(false);
                }
            }

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 28
                iconSize: Theme.fontSizeMedium
                iconName: "close"
                iconColor: Theme.surfaceVariantText
                tooltipText: I18n.tr("Close (Esc)")
                onClicked: root.closed()
            }
        }
    }

    // --------------------------------------------------------- the matches

    StyledRect {
        id: results
        anchors.top: bar.bottom
        anchors.topMargin: Theme.spacingXS
        anchors.left: bar.left
        anchors.right: bar.right
        visible: root.listOpen && root.hits.length > 0
        height: Math.min(resultsList.contentHeight + Theme.spacingXS * 2, root.height * 0.6)
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        border.color: Theme.withAlpha(Theme.outline, 0.3)
        border.width: 1
        clip: true

        DankListView {
            id: resultsList
            anchors.fill: parent
            anchors.margins: Theme.spacingXS
            model: root.hits
            spacing: 2

            delegate: StyledRect {
                id: hitRow

                required property var modelData
                required property int index

                readonly property bool isHighlighted: hitRow.index === root.highlighted

                width: ListView.view.width
                height: hitColumn.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius / 2
                color: hitRow.isHighlighted ? Theme.surfaceHover : "transparent"
                border.color: hitRow.isHighlighted ? Theme.primary : "transparent"
                border.width: hitRow.isHighlighted ? 1 : 0

                MouseArea {
                    id: hitArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // The pointer and the arrows move one highlight, so Enter
                    // always means the row that is lit. On movement, so the
                    // list opening under a still pointer leaves it alone.
                    onPositionChanged: root.highlighted = hitRow.index
                    onClicked: root.choose(hitRow.index)
                }

                Column {
                    id: hitColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Theme.spacingS
                    spacing: 2

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            text: hitRow.modelData.fromMe ? I18n.tr("You") : (hitRow.modelData.senderName || "")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.primary
                        }

                        StyledText {
                            text: root.formatWhen(hitRow.modelData.ts)
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: root.snippet(hitRow.modelData)
                        textFormat: Text.StyledText
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                    }
                }
            }
        }
    }
}
