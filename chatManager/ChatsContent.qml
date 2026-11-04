pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

// Two panes: conversations on the left, the open one on the right.
FocusScope {
    id: root

    // The chat core, handed down from the plugin daemon. It was a shell
    // singleton before this became a plugin, which is why it used to be
    // reachable from anywhere without being passed.
    //
    // Deliberately not called "chat": several of these components already use
    // that name for the conversation being shown, which is a different thing.
    required property var chatCore

    signal closeRequested

    // Whether the window is open, for the composer's drafts.
    property bool onScreen: true

    // Nothing here holds the manager's state stream open. This content is kept
    // loaded for the life of the shell, so counting itself in from here kept
    // the stream running from startup onwards; the daemon follows the window
    // being open instead.

    function takeFocus() {
        searchField.forceActiveFocus();
    }

    // openConversation opens one and hands it the keyboard.
    //
    // The focus half is not optional. Picking a conversation is picking what to
    // write in, and leaving focus in the search box means the first thing typed
    // filters the list instead -- and, after two characters, replaces the
    // conversation with search results. Every way into a conversation from this
    // window goes through here for that reason.
    function openConversation(provider, chatId, ts) {
        if (ts > 0)
            root.chatCore.openChatAt(provider, chatId, ts);
        else
            root.chatCore.openChat(provider, chatId);

        // After the open, so the conversation is on screen by the time it is
        // asked to take focus -- a hidden field cannot hold the keyboard.
        Qt.callLater(() => conversation.takeFocus());
    }

    // Signing in takes over the conversation pane and the keyboard with it.
    // When it is done the panel is gone, and focus with it, so it goes back to
    // the conversation -- unless the search box is where the user has since
    // started typing, which is theirs.
    onAuthProviderChanged: {
        if (root.authProvider !== null || searchField.getActiveFocus())
            return;
        Qt.callLater(() => conversation.takeFocus());
    }

    readonly property bool hasProviders: root.chatCore.providers.length > 0

    // Message search results for the current query. The chat list filters
    // locally as you type; searching message bodies means asking the backend,
    // which is debounced so a query is not sent per keystroke.
    property var messageHits: []
    property bool searching: false

    // Conversations the backend found by name for the current query. The list
    // held here is the two hundred most recent, so a conversation older than
    // that could not be found by typing its name at all; these fill that in.
    property var chatHits: []

    // The conversation the keyboard is on, as an index into visibleChats, or -1.
    //
    // Focus stays in the search box -- typing narrows the list, and the arrows
    // and Enter pick from it -- the way the launcher works, so a conversation
    // is reached without the mouse and without the keys going anywhere else.
    property int highlightIndex: -1

    // Surfaced for the modal, which must not close on Escape while the
    // conversation has something layered over it.
    readonly property bool hasOverlay: conversation.hasOverlay
    readonly property bool holdsEscape: conversation.holdsEscape

    readonly property bool showingResults: searchField.text.trim().length >= 2 && messageHits.length > 0

    function runSearch() {
        const query = searchField.text.trim();
        if (query.length < 2) {
            root.messageHits = [];
            root.chatHits = [];
            return;
        }

        root.searching = true;
        root.chatCore.search(query, (messages, chats) => {
            // An answer to a query that is no longer in the box is not an
            // answer: a slow search finishing after a faster, newer one would
            // otherwise put the old results back.
            if (searchField.text.trim() !== query)
                return;
            root.searching = false;
            root.messageHits = messages || [];
            root.chatHits = chats || [];
        });
    }

    function moveHighlight(step) {
        const count = root.visibleChats.length;
        if (count === 0)
            return;
        const next = root.highlightIndex < 0 ? (step > 0 ? 0 : count - 1) : root.highlightIndex + step;
        root.highlightIndex = Math.max(0, Math.min(count - 1, next));
        chatList.positionViewAtIndex(root.highlightIndex, ListView.Contain);
    }

    function openHighlighted() {
        const chat = root.visibleChats[root.highlightIndex];
        if (!chat) {
            // Nothing here by that name, but it is an address a provider can
            // open: Enter starts it, the same as clicking the offer.
            if (root.startProviders.length > 0)
                root.startConversation(root.startProviders[0].id, root.startHandle);
            return;
        }
        searchField.text = "";
        root.openConversation(chat.provider, chat.id, 0);
    }

    // What the search box holds when it looks like an address -- @someone,
    // #a-room, !a-room-id -- which a provider that can start conversations
    // is offered to open.
    readonly property string startHandle: {
        const query = searchField.text.trim();
        if (query.length < 2 || query.indexOf(" ") !== -1)
            return "";
        const first = query.charAt(0);
        return first === "@" || first === "#" || first === "!" ? query : "";
    }

    readonly property var startProviders: root.startHandle !== "" ? root.chatCore.startChatProviders : []

    // Whether a conversation is being started, so the offer says so instead
    // of being pressed twice.
    property bool starting: false

    function startConversation(providerId, handle) {
        if (root.starting || handle === "")
            return;
        root.starting = true;
        root.chatCore.startChat(providerId, handle, (chatId, error) => {
            root.starting = false;
            if (chatId === "")
                return;
            searchField.text = "";
            root.openConversation(providerId, chatId, 0);
        });
    }

    // The first enabled provider waiting to be signed in, if any. Sign-in takes
    // over the conversation pane, since nothing else there is actionable until
    // it is dealt with.
    readonly property var authProvider: {
        for (let i = 0; i < root.chatCore.providers.length; i++) {
            const provider = root.chatCore.providers[i];
            if (provider.enabled && provider.state === "needsLogin")
                return provider;
        }
        return null;
    }

    // Conversations after the hidden-tag setting and the search box.
    //
    // Hiding is skipped while searching: someone who types a name is looking
    // for that conversation, and refusing to show it because it happens to be
    // archived would be obstinate.
    readonly property var visibleChats: {
        const query = searchField.text.trim().toLowerCase();
        const source = query === "" ? root.chatCore.visibleChats : root.chatCore.chats;

        if (query === "")
            return source;

        const out = [];
        const seen = {};
        for (let i = 0; i < source.length; i++) {
            const chat = source[i];
            const name = (chat.name || "").toLowerCase();
            const preview = (chat.lastText || "").toLowerCase();
            const subject = (chat.subject || "").toLowerCase();
            // And anything the conversation answers to -- a number, an
            // address -- so typing someone's @address finds the chat you
            // already have with them rather than offering to start another.
            const handles = chat.handles || [];
            let byHandle = false;
            for (let h = 0; h < handles.length && !byHandle; h++)
                byHandle = handles[h].toLowerCase().indexOf(query) !== -1;
            if (byHandle || name.indexOf(query) !== -1 || preview.indexOf(query) !== -1 || subject.indexOf(query) !== -1) {
                out.push(chat);
                seen[chat.provider + " " + chat.id] = true;
            }
        }

        // Then whatever the backend found that is not in the list held here.
        for (let i = 0; i < root.chatHits.length; i++) {
            const chat = root.chatHits[i];
            if (!seen[chat.provider + " " + chat.id])
                out.push(chat);
        }
        return out;
    }

    // A list that changes under the highlight keeps it in range -- and nothing
    // more: pushes rebuild this list several times a second during a sync, and
    // putting the highlight back on the first row each time would take it away
    // from whoever was moving it.
    onVisibleChatsChanged: {
        const count = root.visibleChats.length;
        if (root.highlightIndex >= count)
            root.highlightIndex = count - 1;
        else if (root.highlightIndex < 0 && count > 0 && searchField.text.trim() !== "")
            root.highlightIndex = 0;
    }

    readonly property int hiddenCount: root.chatCore.chats.length - root.chatCore.visibleChats.length

    Timer {
        id: searchDebounce
        interval: 250
        onTriggered: root.runSearch()
    }

    Keys.onEscapePressed: event => {
        if (searchField.text !== "") {
            searchField.text = "";
            event.accepted = true;
            return;
        }
        root.closeRequested();
        event.accepted = true;
    }

    Row {
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingM

        // ---------------------------------------------------- conversations

        Item {
            width: 300
            height: parent.height

            Column {
                anchors.fill: parent
                spacing: Theme.spacingS

                Row {
                    id: searchRow
                    width: parent.width
                    spacing: Theme.spacingS

                    DankTextField {
                        id: searchField
                        width: parent.width - syncIndicator.width - Theme.spacingS
                        placeholderText: I18n.tr("Search conversations and messages")
                        leftIconName: "search"
                        showClearButton: true

                        // Typing puts the keyboard on the best match, so
                        // Enter opens it.
                        onTextChanged: {
                            root.highlightIndex = searchField.text.trim() === "" ? -1 : 0;
                            searchDebounce.restart();
                        }

                        // The list is worked from here, so the keys stay where
                        // the typing is. Handing focus to the list instead left
                        // the arrows moving an index nothing drew, and Enter
                        // doing nothing at all.
                        Keys.onDownPressed: event => {
                            root.moveHighlight(1);
                            event.accepted = true;
                        }
                        Keys.onUpPressed: event => {
                            root.moveHighlight(-1);
                            event.accepted = true;
                        }
                        onAccepted: root.openHighlighted()
                    }

                    DankSpinner {
                        id: syncIndicator
                        anchors.verticalCenter: parent.verticalCenter
                        width: visible ? 20 : 0
                        height: 20
                        visible: root.chatCore.syncing
                    }
                }

                // Filtering is invisible otherwise, and a conversation that is
                // simply missing looks like a bug rather than a choice.
                Row {
                    id: filterRow
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.hiddenCount > 0 && searchField.text === ""

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "filter_alt"
                        size: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("%1 hidden by filters").arg(root.hiddenCount)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }

                // An address typed into the search box can be opened from
                // here: a person to message, a room to join.
                Column {
                    id: startColumn
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.startProviders.length > 0

                    Repeater {
                        model: root.startProviders

                        StyledRect {
                            id: offer

                            required property var modelData
                            required property int index

                            width: startColumn.width
                            height: 44
                            radius: Theme.cornerRadius
                            color: offerArea.containsMouse ? Theme.surfaceHover : Theme.withAlpha(Theme.primary, 0.08)
                            // The one Enter starts, when no conversation matches.
                            border.color: offer.index === 0 && root.visibleChats.length === 0 ? Theme.primary : "transparent"
                            border.width: 1

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS
                                spacing: Theme.spacingS

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: root.starting ? "hourglass_empty" : (root.startHandle.charAt(0) === "@" ? "person_add" : "group_add")
                                    size: Theme.iconSize
                                    color: Theme.primary
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - Theme.iconSize - Theme.spacingS
                                    text: {
                                        if (root.starting)
                                            return I18n.tr("Opening %1…").arg(root.startHandle);
                                        return root.startHandle.charAt(0) === "@" ? I18n.tr("Message %1 on %2").arg(root.startHandle).arg(offer.modelData.name) : I18n.tr("Join %1 on %2").arg(root.startHandle).arg(offer.modelData.name);
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    elide: Text.ElideMiddle
                                }
                            }

                            MouseArea {
                                id: offerArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: !root.starting
                                onClicked: root.startConversation(offer.modelData.id, root.startHandle)
                            }
                        }
                    }
                }

                // The list and what is shown in its place share one area, sized
                // to what is left under the search box and the filter line.
                // The empty states used to sit in the column after a list
                // that already took the whole height, which put them just
                // below the bottom of the window where nobody saw them.
                Item {
                    width: parent.width
                    height: parent.height - searchRow.height - Theme.spacingS - (filterRow.visible ? filterRow.height + Theme.spacingS : 0) - (startColumn.visible ? startColumn.height + Theme.spacingS : 0)

                    DankListView {
                        id: chatList
                        anchors.fill: parent
                        clip: true
                        model: root.visibleChats
                        spacing: Theme.spacingXS
                        currentIndex: -1

                        delegate: ChatListItem {
                            required property var modelData
                            required property int index

                            width: chatList.width
                            chat: modelData
                            chatCore: root.chatCore
                            selected: root.chatCore.activeProvider === modelData.provider && root.chatCore.activeChatId === modelData.id
                            highlighted: index === root.highlightIndex

                            onActivated: root.openConversation(modelData.provider, modelData.id, 0)
                            onArchiveToggled: root.chatCore.setArchived(modelData.provider, modelData.id, !modelData.archived)
                            onMuteToggled: root.chatCore.setMuted(modelData.provider, modelData.id, !modelData.muted)
                        }
                    }

                    // Empty states say which situation this is, since the fix
                    // differs: wait for the manager, install a plugin, enable
                    // one, or wait for a conversation.
                    StyledText {
                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingM * 2
                        visible: root.visibleChats.length === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        text: {
                            if (!root.chatCore.available)
                                return I18n.tr("Connecting to the chat manager…");
                            if (!root.hasProviders)
                                return I18n.tr("No chat providers installed.\nAdd one from Settings → Plugins.");
                            if (!root.chatCore.hasEnabledProvider)
                                return I18n.tr("No chat providers enabled.\nTurn one on in Settings → Plugins.");
                            if (root.startProviders.length > 0)
                                return I18n.tr("No conversation with %1 yet.\nPress Enter to start one.").arg(root.startHandle);
                            if (searchField.text !== "")
                                return I18n.tr("No conversations match.");
                            return I18n.tr("No conversations yet.");
                        }
                    }
                }
            }
        }

        Rectangle {
            width: 1
            height: parent.height
            color: Theme.outline
            opacity: 0.2
        }

        // ---------------------------------------------------- conversation

        Item {
            width: parent.width - 300 - Theme.spacingM * 2 - 1
            height: parent.height

            AuthPanel {

                chatCore: root.chatCore
                anchors.fill: parent
                visible: root.authProvider !== null
                provider: root.authProvider
            }

            // Message results take over the conversation pane while searching:
            // the point of the search is to find a message, not to keep reading
            // the one already open.
            ChatSearchResults {
                anchors.fill: parent
                visible: root.authProvider === null && root.showingResults
                hits: root.messageHits
                chatCore: root.chatCore
                query: searchField.text.trim()

                onHitChosen: (provider, chatId, ts) => {
                    // Clear first: the results pane is bound to the query, and
                    // leaving it set keeps the filter over the conversation the
                    // user just asked to read -- and would keep this view from
                    // being the one on screen to take focus.
                    searchField.text = "";
                    root.messageHits = [];
                    root.chatHits = [];
                    searchDebounce.stop();
                    root.openConversation(provider, chatId, ts);
                }
            }

            ConversationView {

                chatCore: root.chatCore
                id: conversation
                anchors.fill: parent
                onScreen: root.onScreen
                visible: root.authProvider === null && !root.showingResults && root.chatCore.hasActiveChat
            }

            StyledText {
                anchors.centerIn: parent
                visible: root.authProvider === null && !root.showingResults && !root.chatCore.hasActiveChat
                text: I18n.tr("Select a conversation")
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }
        }
    }
}
