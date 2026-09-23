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
    // moved with Ctrl+K/J.
    property int selectedIndex: -1

    // Where the view belongs, and whether it is still ours to place.
    //
    // Both are needed because the open conversation is reloaded whole on every
    // state push, and a list whose model is replaced puts itself back where it
    // thinks it was rather than where it was put. So the intended position is
    // remembered and reapplied, until the user scrolls somewhere themselves.
    property int viewPin: -1
    property int viewPinMode: ListView.Beginning
    property bool viewPinned: true

    // Whether this open is still waiting for the messages that decide where it
    // lands. Set when a conversation is opened, cleared by the first page.
    property bool _awaitingUnread: false

    readonly property var selectedMessage: selectedIndex >= 0 && selectedIndex < root.chatCore.messages.length ? root.chatCore.messages[selectedIndex] : null

    // True while anything is layered over the conversation. Escape belongs to
    // the overlay then, and the modal must not act on it.
    readonly property bool hasOverlay: showingHelp || pendingDelete !== null || forwardSource !== null

    // ------------------------------------------------------------- focus
    //
    // The text field holds the keyboard, always, whenever this view is on
    // screen and there is something to type into. It is not a nicety: Enter
    // sends, the shortcuts are chords chosen because a text field does not want
    // them, and a message is typed without aiming first. Focus landing anywhere
    // else means keys that go nowhere and a window that looks broken.
    //
    // So rather than being handed focus once, at the moment a conversation
    // opens, the view takes it back at every point where it could have been
    // lost: an overlay closing, an invitation being answered, the conversation
    // becoming visible, or anything inside here quietly taking it.
    //
    // Focus that has left this view entirely is the one thing left alone -- the
    // search box next door was clicked into on purpose, and a window that
    // argues about that is worse than one that loses focus.

    // An overlay is layered over this view and had the keyboard because this
    // view lent it: closing one gives it straight back, wherever it left it.
    onHasOverlayChanged: {
        if (!hasOverlay)
            Qt.callLater(root.takeFocus);
    }

    // An invitation has no composer; answering it grows one, and the bar that
    // had the keyboard is gone, so nothing else would ever put it there.
    onIsInviteChanged: {
        if (!isInvite)
            Qt.callLater(root.takeFocus);
    }

    onVisibleChanged: {
        if (visible) {
            Qt.callLater(root.keepFocus);
            return;
        }
        // Off the screen, so the keyboard cannot stay here: a hidden text field
        // holds onto it, and what took this view's place -- a sign-in panel,
        // search results -- would look focused while everything typed went into
        // a message that is not on screen.
        composer.releaseFocus();
    }

    // Focus arriving anywhere in here -- a click, a parent handing it over --
    // belongs in the text field.
    onActiveFocusChanged: root.keepFocus()

    // keepFocus puts the keyboard back in the text field when it is still ours
    // to put: something in here took it, or was handed it and did nothing with
    // it. Focus that has left this view is deliberately not chased.
    function keepFocus() {
        if (root.hasOverlay || !root.activeFocus || composer.fieldFocused)
            return;
        root.takeFocus();
    }

    // The view can be built after the conversation was opened: a popout creates
    // its contents as it appears. So it places itself on what is already there,
    // rather than on a signal that has been and gone.
    Component.onCompleted: {
        if (root.chatCore.messages.length > 0)
            root.pinView(root.chatCore.firstUnreadIndex);
        else
            root._awaitingUnread = root.chatCore.hasActiveChat;
    }

    // takeFocus is the way in from outside: a conversation being opened, a
    // window being shown. Inside, keepFocus above is what holds it here.
    function takeFocus() {
        // Nothing to type into while an invitation is unanswered, or while this
        // view is not the thing on screen: focusing a hidden field would
        // swallow the keys that do work.
        if (!root.visible || root.isInvite)
            return;
        composer.takeFocus();
    }

    function answerInvite(accept) {
        if (!root.isInvite)
            return;
        root.chatCore.answerInvite(root.chatCore.activeProvider, root.chatCore.activeChatId, accept);
    }

    // ----------------------------------------------------------- the view

    // pinView parks the view on a message -- or on the newest, with -1 -- and
    // keeps it there through the reloads that follow.
    //
    // Contain for a selection, which only has to stay on screen; Beginning for
    // the unread mark, which belongs at the top with what is unread below it.
    function pinView(index, mode) {
        root.viewPin = index;
        root.viewPinMode = mode === undefined ? ListView.Beginning : mode;
        root.viewPinned = true;
        root.applyPin();
    }

    // applyPin puts the view where it belongs, and keeps saying so for a moment.
    //
    // Once is not enough: the messages and the layout they produce do not
    // arrive together, the list restores its own scroll position when its model
    // is replaced, and a position set before either has settled is quietly
    // dropped -- which is what made opening at the unread divider a coin toss.
    function applyPin() {
        if (!root.viewPinned)
            return;
        root._place();
        pinSettle.attempts = 0;
        pinSettle.restart();
    }

    function _place() {
        if (root.viewPin < 0)
            messageList.positionViewAtEnd();
        else if (root.viewPin < root.chatCore.messages.length)
            messageList.positionViewAtIndex(root.viewPin, root.viewPinMode);
    }

    Timer {
        id: pinSettle

        property int attempts: 0

        interval: 50
        repeat: true
        onTriggered: {
            if (!root.viewPinned || ++pinSettle.attempts > 4) {
                pinSettle.stop();
                return;
            }
            root._place();
        }
    }

    // ------------------------------------------------------------- selection

    function selectPrevious() {
        const count = root.chatCore.messages.length;
        if (count === 0)
            return;
        // From nothing, start at the newest and walk back.
        root.selectedIndex = root.selectedIndex < 0 ? count - 1 : Math.max(0, root.selectedIndex - 1);
        root.pinView(root.selectedIndex, ListView.Contain);
    }

    function selectNext() {
        const count = root.chatCore.messages.length;
        if (count === 0 || root.selectedIndex < 0)
            return;
        root.selectedIndex = Math.min(count - 1, root.selectedIndex + 1);
        root.pinView(root.selectedIndex, ListView.Contain);
    }

    function clearSelection() {
        root.selectedIndex = -1;
        // Following the newest message again if that is already where the view
        // is; otherwise it stays where it was left.
        root.viewPin = -1;
        root.viewPinned = messageList.atYEnd;
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

    // toggleReply answers the selected message, or takes the answer back.
    //
    // The same key both ways: the reply bar is a mode the composer is in, and
    // the way out of a mode is the key that put you in it.
    function toggleReply() {
        if (!root.chatCore.activeSupports("reply"))
            return;

        const msg = root.selectedMessage;
        if (!msg || (root.replyTarget && root.replyTarget.id === msg.id)) {
            root.replyTarget = null;
            return;
        }
        root.replyTarget = msg;
    }

    function forwardSelected() {
        if (root.selectedMessage && (root.selectedMessage.text || "") !== "")
            root.forwardSource = root.selectedMessage;
    }

    Connections {
        target: root.chatCore

        // Opening, rather than the conversation changing: opening the one
        // already open -- from the launcher, or from the unread cycle landing
        // back on it -- is still an open, and still has to place the view.
        function onChatOpened(provider, chatId) {
            root.replyTarget = null;
            root.selectedIndex = -1;
            root.pendingDelete = null;

            // Where it lands is decided by the page that is still on its way:
            // the read position comes back with it. Until then, the newest
            // message, so an opening conversation is never blank.
            root._awaitingUnread = true;
            root.pinView(-1);
        }

        // Anything that changes the conversation without opening one -- a
        // declined invitation closing the view, mostly.
        function onActiveChatIdChanged() {
            root.replyTarget = null;
            root.selectedIndex = -1;
            root.pendingDelete = null;
        }

        function onMessagesChanged() {
            if (root._awaitingUnread && root.chatCore.messages.length > 0) {
                root._awaitingUnread = false;
                // Beginning, so the divider is the first thing on screen and
                // the unread messages read downwards from it. Nothing unread
                // means the newest message, as ever.
                root.pinView(root.chatCore.firstUnreadIndex);
                return;
            }

            // Every push reloads the page, and the list puts itself back where
            // it was rather than where it was told to be. By name rather than
            // as a closure, so a burst of pushes queues one of these and not
            // one per push.
            Qt.callLater(root.applyPin);
        }
    }

    // Shortcuts rather than Keys handlers: the composer holds real focus and
    // consumes most key events, so a handler on this scope would never see them.
    //
    // Ctrl throughout, where these were Alt: one modifier for everything the
    // conversation does is one thing to remember, and it is the one every other
    // key here already used.
    Shortcut {
        sequences: ["Ctrl+K"]
        onActivated: root.selectPrevious()
    }

    Shortcut {
        sequences: ["Ctrl+J"]
        onActivated: root.selectNext()
    }

    Shortcut {
        sequences: ["Ctrl+R"]
        onActivated: root.toggleReply()
    }

    Shortcut {
        sequences: ["Ctrl+F"]
        onActivated: root.forwardSelected()
    }

    // Opens the selected message's attachment or link. Ctrl+Enter rather than
    // Shift+Enter, and only with something selected, so plain Enter keeps
    // meaning send and nothing else has to be thought about while typing.
    Shortcut {
        sequences: ["Ctrl+Return", "Ctrl+Enter"]
        enabled: root.selectedIndex >= 0 && !root.hasOverlay
        onActivated: root.openSelected()
    }

    // Only fires when the composer does not hold focus, which is rare: an
    // editable text field answers for the paste shortcut first, so the composer
    // takes that key itself -- see pasteKeys there.
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

    // Ctrl+Delete rather than plain Delete, which never reached this: an
    // editable text field answers for Delete before the shortcut system is
    // asked, and the composer always holds focus. Taking the key from the field
    // instead would mean a draft that cannot be edited while a message happens
    // to be selected, which is a worse trade than a modifier.
    Shortcut {
        sequences: ["Ctrl+Shift+Delete"]
        enabled: root.selectedIndex >= 0 && !root.hasOverlay
        onActivated: root.requestDelete(root.selectedMessage, true)
    }

    Shortcut {
        sequences: ["Ctrl+Delete"]
        enabled: root.selectedIndex >= 0 && !root.hasOverlay
        onActivated: root.requestDelete(root.selectedMessage, false)
    }

    // Only ever live on an unanswered invitation, so these cannot collide with
    // anything the conversation itself uses.
    //
    // Shifted, where the rest are not: plain Ctrl+Y is redo as far as any text
    // field is concerned, and it never reaches here while one has focus -- as
    // the conversation list's search box does. Both answers keep the same shape
    // rather than only the one that had to move, and the extra key is no loss
    // on a choice this consequential. The bar itself has both as buttons.
    Shortcut {
        sequences: ["Ctrl+Shift+Y"]
        enabled: root.isInvite && !root.hasOverlay
        onActivated: root.answerInvite(true)
    }

    Shortcut {
        sequences: ["Ctrl+Shift+N"]
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

                // The user taking the view somewhere is the end of our claim on
                // it: a message arriving must not drag them back down from what
                // they are reading.
                onIsUserScrollingChanged: {
                    if (messageList.isUserScrolling)
                        root.viewPinned = false;
                }

                // Scrolling back to the bottom is the user having caught up, so
                // the view follows the newest message again. Only when they did
                // the scrolling: a list momentarily reports itself at the end
                // while its model is being replaced.
                onAtYEndChanged: {
                    if (messageList.atYEnd && messageList.isUserScrolling) {
                        root.viewPin = -1;
                        root.viewPinned = true;
                    }
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

            // Anything in here that takes the keyboard gives it straight back.
            onFieldFocusedChanged: {
                if (!composer.fieldFocused)
                    Qt.callLater(root.keepFocus);
            }

            // A field that cannot be typed into cannot hold the keyboard
            // either, and until a provider has reported what it can do, this is
            // one of those. That answer arrives over a socket, so it can easily
            // be later than the conversation it belongs to -- and without this
            // the window would sit there, open and ready, with nowhere for the
            // typing to go.
            onCanSendChanged: {
                if (composer.canSend)
                    Qt.callLater(root.takeFocus);
            }

            onReplyCleared: root.replyTarget = null
            onSent: {
                root.replyTarget = null;
                root.selectedIndex = -1;
                // Writing is catching up, whatever was left unread above.
                root.pinView(-1);
            }
        }
    }
}
