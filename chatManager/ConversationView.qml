pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

// The open conversation: header, messages, composer.
FocusScope {
    id: root

    // The chat core, handed down from the plugin daemon. It was a shell
    // singleton before this became a plugin, which is why it used to be
    // reachable from anywhere without being passed.
    //
    // Deliberately not called "chat": several of these components already use
    // that name for the conversation being shown, which is a different thing.
    required property var chatCore

    readonly property var chat: root.chatCore.activeChat
    readonly property string chatName: chat?.name || chat?.subject || root.chatCore.activeChatId

    // An invitation is a conversation you are not in yet. Nothing can be sent
    // into it, so the composer gives way to the two answers there are.
    readonly property bool isInvite: root.chatCore.isInvite(root.chat) && root.chatCore.activeSupports("invites")

    // What the user is replying to, or null. Cleared when the conversation
    // changes, since a reply target from another chat is meaningless.
    property var replyTarget: null

    // The message awaiting a destination, or null.
    property var forwardSource: null

    property bool showingHelp: false

    // A pending destructive action, held until confirmed. Deleting a message is
    // not undoable, and a mistyped key should not be enough to do it.
    property var pendingDelete: null
    property bool pendingDeleteForEveryone: false

    // The selected message, as an index into root.chatCore.messages.
    //
    // Deliberately not real focus: the composer keeps that, so typing always
    // reaches the text field. This is a border drawn around one message and
    // moved with Alt+K/J.
    property int selectedIndex: -1

    // Opening a conversation with unread messages puts the view at the first
    // of them rather than at the bottom. These track that: one waiting for the
    // messages to arrive, one keeping the view there afterwards instead of
    // yanking it to the newest message on the next refresh.
    property bool _awaitingUnreadJump: false
    property bool _heldAtUnread: false

    readonly property var selectedMessage: selectedIndex >= 0 && selectedIndex < root.chatCore.messages.length ? root.chatCore.messages[selectedIndex] : null

    // True while anything is layered over the conversation. Escape belongs to
    // the overlay then, and the modal must not act on it.
    readonly property bool hasOverlay: showingHelp || pendingDelete !== null || forwardSource !== null

    // Whatever closes an overlay puts focus back on the composer, so Escape
    // keeps working and typing keeps landing in the text field.
    onHasOverlayChanged: {
        if (!hasOverlay)
            Qt.callLater(() => root.takeFocus());
    }

    function takeFocus() {
        // Nothing to type into while an invitation is unanswered, and focusing
        // a hidden field would swallow the keys that do work here.
        if (root.isInvite)
            return;
        composer.takeFocus();
    }

    function answerInvite(accept) {
        if (!root.isInvite)
            return;
        root.chatCore.answerInvite(root.chatCore.activeProvider, root.chatCore.activeChatId, accept);
    }

    // ------------------------------------------------------------- selection

    function selectPrevious() {
        const count = root.chatCore.messages.length;
        if (count === 0)
            return;
        // From nothing, start at the newest and walk back.
        root.selectedIndex = root.selectedIndex < 0 ? count - 1 : Math.max(0, root.selectedIndex - 1);
        messageList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }

    function selectNext() {
        const count = root.chatCore.messages.length;
        if (count === 0 || root.selectedIndex < 0)
            return;
        root.selectedIndex = Math.min(count - 1, root.selectedIndex + 1);
        messageList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }

    function clearSelection() {
        root.selectedIndex = -1;
    }

    // --------------------------------------------------------------- actions

    function openSelected() {
        const msg = root.selectedMessage;
        if (!msg)
            return;

        if (msg.mediaPath) {
            Quickshell.execDetached(["xdg-open", msg.mediaPath]);
            return;
        }
        if (msg.mediaRef) {
            root.chatCore.fetchMedia(root.chatCore.activeProvider, root.chatCore.activeChatId, msg.id, path => {
                if (path)
                    Quickshell.execDetached(["xdg-open", path]);
            });
            return;
        }

        const link = (msg.text || "").match(/https?:\/\/[^\s]+/);
        if (link)
            Quickshell.execDetached(["xdg-open", link[0]]);
    }

    // copyMessage puts the message on the clipboard: an attachment goes as a
    // file, so it can be pasted into anything that takes one, and text as text.
    function copyMessage(msg) {
        if (!msg)
            return;

        if (msg.mediaPath) {
            root.chatCore.copyFileToClipboard(msg.mediaPath);
            return;
        }

        if (msg.mediaRef) {
            root.chatCore.fetchMedia(root.chatCore.activeProvider, root.chatCore.activeChatId, msg.id, path => {
                if (path)
                    root.chatCore.copyFileToClipboard(path);
            });
            return;
        }

        if ((msg.text || "") === "")
            return;

        // wl-copy rather than the clipboard manager, so text lands the same way
        // an attachment does and is immediately readable by wl-paste.
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", msg.text]);
        ToastService.showInfo(I18n.tr("Copied to clipboard"));
    }

    function requestDelete(msg, forEveryone) {
        if (!msg)
            return;
        if (forEveryone && !root.chatCore.activeSupports("revoke"))
            return;
        root.pendingDeleteForEveryone = forEveryone;
        root.pendingDelete = msg;
    }

    function confirmDelete() {
        const msg = root.pendingDelete;
        if (!msg)
            return;

        if (root.pendingDeleteForEveryone)
            root.chatCore.revoke(root.chatCore.activeProvider, root.chatCore.activeChatId, msg.id);
        else
            root.chatCore.deleteLocal(root.chatCore.activeProvider, root.chatCore.activeChatId, msg.id);

        root.pendingDelete = null;
        root.clearSelection();
    }

    function replyToSelected() {
        if (root.selectedMessage && root.chatCore.activeSupports("reply"))
            root.replyTarget = root.selectedMessage;
    }

    function forwardSelected() {
        if (root.selectedMessage && (root.selectedMessage.text || "") !== "")
            root.forwardSource = root.selectedMessage;
    }

    Connections {
        target: root.chatCore

        function onActiveChatIdChanged() {
            root.replyTarget = null;
            root.selectedIndex = -1;
            root.pendingDelete = null;
            // The mark is set as the conversation opens, before its messages
            // have been asked for -- so what is known here is only whether to
            // expect one.
            root._awaitingUnreadJump = root.chatCore.unreadMarkTs > 0;
            root._heldAtUnread = false;
            Qt.callLater(() => messageList.positionViewAtEnd());
        }

        function onMessagesChanged() {
            if (root._awaitingUnreadJump) {
                const at = root.chatCore.firstUnreadIndex;
                if (at > 0) {
                    root._awaitingUnreadJump = false;
                    root._heldAtUnread = true;
                    // Beginning, so the divider is the first thing on screen
                    // and the unread messages read downwards from it.
                    Qt.callLater(() => messageList.positionViewAtIndex(at, ListView.Beginning));
                    return;
                }
                if (root.chatCore.messages.length > 0) {
                    // Messages arrived and none of them is behind a mark: there
                    // is nowhere to jump to, so stop waiting for one.
                    root._awaitingUnreadJump = false;
                }
            }

            // Stay pinned to the newest message unless the user has scrolled up
            // to read something -- including the unread mark they were put at.
            if (messageList.atYEnd || (root.selectedIndex < 0 && !root._heldAtUnread))
                Qt.callLater(() => messageList.positionViewAtEnd());
        }
    }

    // Shortcuts rather than Keys handlers: the composer holds real focus and
    // consumes most key events, so a handler on this scope would never see them.
    Shortcut {
        sequences: ["Alt+K"]
        onActivated: root.selectPrevious()
    }

    Shortcut {
        sequences: ["Alt+J"]
        onActivated: root.selectNext()
    }

    Shortcut {
        sequences: ["Alt+R"]
        onActivated: root.replyToSelected()
    }

    Shortcut {
        sequences: ["Alt+F"]
        onActivated: root.forwardSelected()
    }

    // Paste is intercepted rather than left to the text field, which consumes
    // Ctrl+V before anything wrapping it is told. The composer then handles
    // both cases: an image is staged, text is inserted at the cursor.
    Shortcut {
        sequences: ["Ctrl+V"]
        enabled: !root.hasOverlay
        onActivated: composer.paste()
    }

    // Ctrl+Shift+C rather than Ctrl+C: the composer always holds focus, so
    // plain Ctrl+C has to stay available for the text the user selected there.
    Shortcut {
        sequences: ["Ctrl+Shift+C"]
        enabled: root.selectedIndex >= 0
        onActivated: root.copyMessage(root.selectedMessage)
    }

    Shortcut {
        sequences: ["Shift+Delete"]
        enabled: root.selectedIndex >= 0 && !root.hasOverlay
        onActivated: root.requestDelete(root.selectedMessage, true)
    }

    Shortcut {
        sequences: ["Delete"]
        enabled: root.selectedIndex >= 0 && !root.hasOverlay
        onActivated: root.requestDelete(root.selectedMessage, false)
    }

    // Only ever live on an unanswered invitation, so these cannot collide with
    // anything the conversation itself uses.
    Shortcut {
        sequences: ["Alt+Y"]
        enabled: root.isInvite && !root.hasOverlay
        onActivated: root.answerInvite(true)
    }

    Shortcut {
        sequences: ["Alt+N"]
        enabled: root.isInvite && !root.hasOverlay
        onActivated: root.answerInvite(false)
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            if (root.pendingDelete) {
                root.pendingDelete = null;
                event.accepted = true;
                return;
            }
            if (root.showingHelp) {
                root.showingHelp = false;
                event.accepted = true;
                return;
            }
            if (root.selectedIndex >= 0) {
                root.clearSelection();
                event.accepted = true;
                return;
            }
        }

        // Shift+Enter opens the selected message's attachment or link. Plain
        // Enter always sends, because the composer always holds focus.
        if ((event.modifiers & Qt.ShiftModifier) && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            if (root.selectedIndex >= 0) {
                root.openSelected();
                event.accepted = true;
            }
        }
    }

    // ------------------------------------------------------------- overlays

    ChatKeybindHelp {
        anchors.fill: parent
        z: 20
        visible: root.showingHelp
        focus: visible
        onDismissed: root.showingHelp = false
    }

    ChatDeleteConfirm {
        anchors.fill: parent
        z: 25
        visible: root.pendingDelete !== null
        focus: visible
        forEveryone: root.pendingDeleteForEveryone
        message: root.pendingDelete

        onConfirmed: root.confirmDelete()
        onCancelled: root.pendingDelete = null
    }

    // Destination picker for a forward. An overlay rather than a separate
    // window: it is a short-lived choice about the conversation already open.
    ChatForwardPicker {
        chatCore: root.chatCore
        anchors.fill: parent
        z: 10
        visible: root.forwardSource !== null
        focus: visible
        source: root.forwardSource

        onCancelled: root.forwardSource = null
        onPicked: (provider, chatId) => {
            root.chatCore.forward(provider, chatId, root.forwardSource?.text ?? "");
            root.forwardSource = null;
        }
    }

    Column {
        anchors.fill: parent
        spacing: 0

        // ------------------------------------------------------------ header

        Item {
            width: parent.width
            height: 52

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: headerActions.left
                anchors.rightMargin: Theme.spacingS
                spacing: Theme.spacingS

                DankCircularImage {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 34
                    height: 34
                    imageSource: root.chat?.avatarPath ? "file://" + root.chatCore.avatarPath : ""
                    fallbackText: root.chatName.charAt(0).toUpperCase()
                    fallbackIcon: "person"
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 34 - Theme.spacingS
                    spacing: 0

                    StyledText {
                        width: parent.width
                        text: root.chatName
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    // Who this is, in the service's own terms: the number or
                    // address they are reachable at, and which service it is.
                    // The same person can appear on more than one.
                    StyledText {
                        width: parent.width
                        text: {
                            const parts = [];
                            const handles = root.chat?.handles ?? [];
                            for (let i = 0; i < handles.length; i++)
                                parts.push(handles[i]);

                            const provider = root.chatCore.providerById(root.chatCore.activeProvider);
                            parts.push(provider ? provider.name : root.chatCore.activeProvider);

                            if (root.chat?.isGroup)
                                parts.push(I18n.tr("Group"));

                            return parts.join("  ·  ");
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }
            }

            Row {
                id: headerActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                DankActionButton {
                    buttonSize: 32
                    iconName: "help"
                    iconColor: Theme.surfaceVariantText
                    tooltipText: I18n.tr("Keyboard Shortcuts")
                    onClicked: root.showingHelp = true
                }

                DankActionButton {
                    buttonSize: 32
                    iconName: (root.chat?.muted ?? false) ? "notifications" : "notifications_off"
                    iconColor: Theme.surfaceVariantText
                    tooltipText: (root.chat?.muted ?? false) ? I18n.tr("Unmute") : I18n.tr("Mute")
                    onClicked: root.chatCore.setMuted(root.chatCore.activeProvider, root.chatCore.activeChatId, !(root.chat?.muted ?? false))
                }

                DankActionButton {
                    buttonSize: 32
                    iconName: (root.chat?.archived ?? false) ? "unarchive" : "archive"
                    iconColor: Theme.surfaceVariantText
                    tooltipText: (root.chat?.archived ?? false) ? I18n.tr("Unarchive") : I18n.tr("Archive")
                    onClicked: root.chatCore.setArchived(root.chatCore.activeProvider, root.chatCore.activeChatId, !(root.chat?.archived ?? false))
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.outline
            opacity: 0.2
        }

        // ---------------------------------------------------------- messages

        Item {
            width: parent.width
            height: parent.height - 52 - 1 - (root.isInvite ? inviteBar.height : composer.height)

            DankListView {
                id: messageList
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                clip: true
                model: root.chatCore.messages
                spacing: Theme.spacingXS

                // Chronological, top to bottom, parked at the end. An inverted
                // list renders a chronological model newest-first and makes
                // "scroll to the bottom" mean the wrong end of the history.
                verticalLayoutDirection: ListView.TopToBottom

                // A column rather than the bubble alone, so the unread mark
                // can sit above the message it belongs to without the bubble
                // itself having to know anything about it.
                delegate: Column {
                    id: messageRow

                    required property var modelData
                    required property int index

                    width: messageList.width
                    spacing: 0

                    ChatUnreadDivider {
                        width: parent.width
                        // Never at the very top: with nothing above it, the
                        // line says only that the conversation starts here.
                        visible: messageRow.index > 0 && messageRow.index === root.chatCore.firstUnreadIndex
                    }

                    MessageBubble {
                        chatCore: root.chatCore

                        width: parent.width
                        message: messageRow.modelData
                        selected: root.selectedIndex === messageRow.index
                        previousMessage: messageRow.index > 0 ? root.chatCore.messages[messageRow.index - 1] : null

                        onReplyRequested: root.replyTarget = messageRow.modelData
                        onForwardRequested: root.forwardSource = messageRow.modelData
                        onCopyRequested: root.copyMessage(messageRow.modelData)
                        onDeleteRequested: root.requestDelete(messageRow.modelData, root.chatCore.activeSupports("revoke"))
                    }
                }

                // Older messages page in at the top, which is where the
                // conversation continues backwards.
                onAtYBeginningChanged: {
                    if (atYBeginning && root.chatCore.hasMoreHistory && !root.chatCore.loadingHistory)
                        root.chatCore.loadOlder();
                }

                // Reaching the bottom is the user having caught up, so the
                // view goes back to following the newest message.
                onAtYEndChanged: {
                    if (atYEnd)
                        root._heldAtUnread = false;
                }
            }

            DankSpinner {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Theme.spacingS
                width: 24
                height: 24
                visible: root.chatCore.loadingHistory && root.chatCore.messages.length > 0
            }

            StyledText {
                anchors.centerIn: parent
                visible: root.chatCore.messages.length === 0 && !root.chatCore.loadingHistory
                text: I18n.tr("No messages yet")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        // ------------------------------------------- invitation, or composer

        ChatInviteBar {
            id: inviteBar
            width: parent.width
            visible: root.isInvite
            // The provider's own wording for the invitation, which is already
            // the conversation's activity line.
            prompt: root.chat?.lastText ?? ""

            onAccepted: root.answerInvite(true)
            onDeclined: root.answerInvite(false)
        }

        Composer {

            chatCore: root.chatCore
            id: composer
            width: parent.width
            visible: !root.isInvite
            replyTarget: root.replyTarget

            onReplyCleared: root.replyTarget = null
            onSent: {
                root.replyTarget = null;
                root.clearSelection();
                // Writing is catching up, whatever was left unread above.
                root._heldAtUnread = false;
                Qt.callLater(() => messageList.positionViewAtEnd());
            }
        }
    }
}
