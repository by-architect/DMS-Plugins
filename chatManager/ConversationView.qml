pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "links.js" as Links

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

    // The message awaiting a reaction, or null.
    property var reactTarget: null

    // Whether the emoji picker is open, to put one in the message.
    property bool pickingEmoji: false

    // The message of ours being edited, or null. The composer is in that mode
    // for as long as this is set.
    property var editTarget: null

    property bool showingHelp: false

    // Whether the search bar is open: Ctrl+Shift+F, finding a message in this
    // conversation. An overlay as far as the keyboard goes -- its field has it
    // while it is up, and Escape closes it.
    property bool searching: false

    // The search result to select once the page around it has loaded, when
    // it was too far back to page to: { key, id }, or null. See jumpToHit.
    property var _selectOnLoad: null

    // Whether the window or popout this is in is the one on screen. Handed
    // down to the composer, which keeps each conversation's draft and so has
    // to know when it stops being the one being typed into.
    property bool onScreen: true

    // A pending destructive action, held until confirmed. Deleting a message is
    // not undoable, and a mistyped key should not be enough to do it.
    property var pendingDelete: null
    property bool pendingDeleteForEveryone: false

    // The selected message, by id.
    //
    // Deliberately not real focus: the composer keeps that, so typing always
    // reaches the text field. This is a border drawn around one message and
    // moved with Ctrl+K/J.
    //
    // By id rather than by position, because positions move: older pages
    // arrive above, and a refresh can take a message out of the middle. Held
    // as an index, the selection slid onto a neighbour when that happened --
    // and the next Ctrl+R answered, or Ctrl+Delete removed, somebody else's
    // message.
    property string selectedId: ""
    readonly property int selectedIndex: root.chatCore.indexOfMessage(root.selectedId)

    // Where the view belongs, and whether it is still ours to place.
    //
    // Both are needed because the open conversation's list is replaced when
    // it changes, and a list whose model is replaced puts itself back where it
    // thinks it was rather than where it was put. So the intended position is
    // remembered and reapplied, until the user scrolls somewhere themselves.
    //
    // The message the view is pinned to, by id for the same reason as the
    // selection; empty means the newest, following the conversation as it
    // grows.
    property string viewPinId: ""
    property int viewPinMode: ListView.Beginning
    property bool viewPinned: true

    // Whether this open is still waiting for the messages that decide where it
    // lands. Set when a conversation is opened, cleared by the first page.
    property bool _awaitingUnread: false

    readonly property var selectedMessage: selectedIndex >= 0 ? root.chatCore.messages[selectedIndex] : null

    // True while anything is layered over the conversation. Escape belongs to
    // the overlay then, and the modal must not act on it.
    readonly property bool hasOverlay: showingHelp || pendingDelete !== null || forwardSource !== null || reactTarget !== null || pickingEmoji || searching

    // Whether Escape is this view's to answer rather than the window's to
    // close on: an overlay, or an edit -- which is a mode the composer is in,
    // not an overlay, since the text field keeps the keyboard throughout --
    // or the "@" picker being open over the composer, which Escape closes.
    readonly property bool holdsEscape: hasOverlay || editTarget !== null || composer.completing

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
    // While one is up the keyboard is the overlay's, and any request still
    // being retried is called off rather than left to fight it.
    onHasOverlayChanged: {
        if (hasOverlay) {
            focusSettle.stop();
            return;
        }
        Qt.callLater(root.takeFocus);
    }

    // An invitation has no composer; answering it grows one, and the bar that
    // had the keyboard is gone, so nothing else would ever put it there.
    //
    // The other way round matters as much. A hidden field keeps the keyboard
    // in Qt Quick, so an invitation opened while the composer had it left
    // typing going into a box nobody could see -- and Enter sending it into a
    // conversation that has not been joined. The keyboard goes to this view
    // instead, where Escape and the invitation's own keys still work.
    onIsInviteChanged: {
        if (!isInvite) {
            Qt.callLater(root.takeFocus);
            return;
        }
        focusSettle.stop();
        if (composer.fieldFocused) {
            composer.releaseFocus();
            root.forceActiveFocus();
        }
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
    // belongs in the text field. Focus leaving the view altogether is the user
    // putting it somewhere on purpose, which also calls off any request still
    // being retried below.
    onActiveFocusChanged: {
        if (!root.activeFocus)
            focusSettle.stop();
        root.keepFocus();
    }

    // Asking for focus once is not enough the first time a chat is opened after
    // a reload, which is the one time all of this is happening at once: the
    // popout's window is being created, the compositor has not handed it the
    // keyboard yet, and the provider that says whether this conversation can be
    // sent to has not answered, so the text field is still disabled and cannot
    // hold focus at all. A request made into any of that is dropped, and
    // nothing asked again -- which is why the first chat opened after a restart
    // came up looking ready with the keyboard pointing at nothing.
    //
    // So the request repeats for a moment and stops the instant it lands. It is
    // the same shape as the settle that puts the message list where it belongs:
    // a state that has to be reached, rather than one call and hope.
    Timer {
        id: focusSettle

        property int attempts: 0

        interval: 60
        repeat: true
        onTriggered: {
            if (composer.fieldFocused || ++focusSettle.attempts > 12) {
                focusSettle.stop();
                return;
            }
            root._focus();
        }
    }

    // keepFocus puts the keyboard back in the text field when it is still ours
    // to put: something in here took it, or was handed it and did nothing with
    // it. Focus that has left this view is deliberately not chased.
    function keepFocus() {
        // An invitation has no composer to give it to: the view itself holds
        // the keyboard then, on purpose.
        if (root.hasOverlay || root.isInvite || !root.activeFocus || composer.fieldFocused)
            return;
        root.takeFocus();
    }

    // The view can be built after the conversation was opened: a popout creates
    // its contents as it appears. So it places itself on what is already there,
    // rather than on a signal that has been and gone.
    Component.onCompleted: {
        root._syncRows();
        if (root.chatCore.messages.length > 0)
            root.pinView(root.chatCore.firstUnreadIndex);
        else
            root._awaitingUnread = root.chatCore.hasActiveChat;
    }

    // takeFocus is the way in from outside: a conversation being opened, a
    // window being shown. Inside, keepFocus above is what holds it here.
    //
    // It asks now and keeps asking for a moment, because on a cold start the
    // answer is no until several other things have happened -- see focusSettle.
    function takeFocus() {
        root._focus();
        focusSettle.attempts = 0;
        focusSettle.restart();
    }

    function _focus() {
        // Nothing to type into while an invitation is unanswered, or while this
        // view is not the thing on screen: focusing a hidden field would
        // swallow the keys that do work. An overlay has the keyboard for as
        // long as it is up, and taking it back would be taking it from the
        // question it is asking.
        if (!root.visible || root.isInvite || root.hasOverlay)
            return;
        composer.takeFocus();
    }

    // providerStateText says why a provider is not sending, or "" when it is.
    function providerStateText(provider) {
        if (!provider || !provider.enabled)
            return "";
        switch (provider.state) {
        case "connected":
            return "";
        case "connecting":
            return I18n.tr("connecting…");
        case "needsLogin":
            return I18n.tr("signed out");
        default:
            return I18n.tr("offline");
        }
    }

    // startsDay is whether a message is the first of its day on screen.
    function startsDay(index) {
        const messages = root.chatCore.messages;
        if (index < 0 || index >= messages.length)
            return false;
        if (index === 0)
            return true;
        return new Date(messages[index - 1].ts || 0).toDateString() !== new Date(messages[index].ts || 0).toDateString();
    }

    // dayLabel names a day the way people say it: today, yesterday, a weekday
    // for this week, and a date before that -- with the year only once it is
    // not this one.
    function dayLabel(ts) {
        if (!ts)
            return "";
        const date = new Date(ts);
        const now = new Date();
        const startOf = d => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
        const days = Math.round((startOf(now) - startOf(date)) / 86400000);

        if (days === 0)
            return I18n.tr("Today");
        if (days === 1)
            return I18n.tr("Yesterday");
        if (days > 1 && days < 7)
            return date.toLocaleDateString(Qt.locale(), "dddd");
        if (date.getFullYear() === now.getFullYear())
            return date.toLocaleDateString(Qt.locale(), "d MMMM");
        return date.toLocaleDateString(Qt.locale(), "d MMMM yyyy");
    }

    function answerInvite(accept) {
        if (!root.isInvite)
            return;
        root.chatCore.answerInvite(root.chatCore.activeProvider, root.chatCore.activeChatId, accept);
    }

    // ----------------------------------------------------------- the rows

    // The message list's rows: one per message, by id, in the order of
    // chatCore.messages. See _syncRows.
    ListModel {
        id: messageRows
    }

    // The ids in messageRows, in order. Read far more often than the rows
    // change, and cheaper than asking the model for each one.
    property var _rowIds: []

    // _syncRows brings the rows in line with the messages, changing only what
    // changed, and says whether it had to start again instead.
    //
    // The list used to be given chatCore.messages itself. Every push replaces
    // that array, and a list whose model is replaced throws every row away and
    // lays them out again from wherever it thinks it was -- DankListView even
    // puts the view back where the user last scrolled, which for a
    // conversation just opened is some other conversation's place. That was
    // the view jumping up and down after opening at the unread mark, and again
    // whenever anything arrived while reading: rows rebuilt, the view thrown
    // somewhere, then put back. Now a row is added where a message arrived and
    // removed where one went, and the list keeps everything else where it is
    // -- including a page of older messages arriving above, which the list
    // grows upwards into without moving what is on screen.
    function _syncRows() {
        const messages = root.chatCore.messages;
        const ids = root._rowIds;

        const wanted = {};
        for (let i = 0; i < messages.length; i++)
            wanted[messages[i].id] = i;

        // Messages do not change places, so what is left of the rows is in
        // their order. Starting again is right when it is not, and when
        // nothing is left: a conversation opened, or emptied.
        let kept = 0;
        let last = -1;
        let ordered = true;
        for (let r = 0; r < ids.length; r++) {
            const at = wanted[ids[r]];
            if (at === undefined)
                continue;
            if (at <= last) {
                ordered = false;
                break;
            }
            last = at;
            kept++;
        }

        if (!ordered || kept === 0) {
            messageRows.clear();
            if (messages.length > 0)
                messageRows.append(messages.map(m => ({
                            "mid": m.id
                        })));
            root._rowIds = messages.map(m => m.id);
            return true;
        }

        const next = ids.slice();
        // What has gone, from the end so the places still hold.
        for (let r = next.length - 1; r >= 0; r--) {
            if (wanted[next[r]] === undefined) {
                messageRows.remove(r);
                next.splice(r, 1);
            }
        }
        // What is new, a run at a time.
        let r = 0;
        for (let i = 0; i < messages.length;) {
            if (r < next.length && next[r] === messages[i].id) {
                r++;
                i++;
                continue;
            }
            const run = [];
            while (i < messages.length && !(r < next.length && next[r] === messages[i].id)) {
                run.push(messages[i].id);
                i++;
            }
            messageRows.insert(r, run.map(id => ({
                        "mid": id
                    })));
            next.splice(r, 0, ...run);
            r += run.length;
        }
        root._rowIds = next;
        return false;
    }

    // _anchor is where the reader is: the first message on screen, and how
    // far its top is from the top of the view.
    function _anchor() {
        const top = messageList.contentY;
        // A few points down, since the very top can fall in the gap between
        // two rows.
        for (let dy = 0; dy < 64; dy += 4) {
            const r = messageList.indexAt(1, top + dy);
            if (r < 0 || r >= root._rowIds.length)
                continue;
            const item = messageList.itemAtIndex(r);
            if (item)
                return {
                    "id": root._rowIds[r],
                    "offset": item.y - top
                };
        }
        return null;
    }

    // _restoreAnchor puts that message back where it was, if the rows changing
    // moved it.
    //
    // The list keeps what is on screen in place by itself when rows arrive
    // above it -- except when the first of them was itself on screen, which is
    // exactly the case when reaching the top asks for an older page. Then the
    // page would push the reader down to its own top.
    function _restoreAnchor(anchor) {
        const r = root._rowIds.indexOf(anchor.id);
        if (r < 0)
            return;
        messageList.forceLayout();
        let item = messageList.itemAtIndex(r);
        if (!item) {
            messageList.positionViewAtIndex(r, ListView.Beginning);
            item = messageList.itemAtIndex(r);
            if (!item)
                return;
        }
        const drift = (item.y - messageList.contentY) - anchor.offset;
        if (Math.abs(drift) < 1)
            return;
        const lowest = messageList.originY;
        const highest = Math.max(lowest, messageList.originY + messageList.contentHeight - messageList.height);
        messageList.contentY = Math.max(lowest, Math.min(highest, messageList.contentY + drift));
    }

    // ----------------------------------------------------------- the view

    // pinView parks the view on a message -- or on the newest, with -1 -- and
    // keeps it there through the reloads that follow.
    //
    // Contain for a selection, which only has to stay on screen; Beginning for
    // the unread mark, which belongs at the top with what is unread below it.
    function pinView(index, mode) {
        const msg = index >= 0 ? root.chatCore.messages[index] : null;
        root.viewPinId = msg ? msg.id : "";
        root.viewPinMode = mode === undefined ? ListView.Beginning : mode;
        root.viewPinned = true;
        root.applyPin();
    }

    // applyPin puts the view where it belongs, and keeps saying so for a moment.
    //
    // Once is not always enough: the rows a page brings are laid out over the
    // next frame or two, and a position set before they settle can be off by
    // their difference. The repeats stop the moment the user moves the view
    // themselves, so they never fight a scroll.
    function applyPin() {
        if (!root.viewPinned)
            return;
        root._place();
        pinSettle.attempts = 0;
        pinSettle.restart();
    }

    function _place() {
        if (root.viewPinId === "") {
            messageList.positionViewAtEnd();
            return;
        }
        // A pinned message that has gone -- deleted, or trimmed -- leaves
        // the view where it is rather than guessing at a neighbour.
        const at = root.chatCore.indexOfMessage(root.viewPinId);
        if (at >= 0)
            messageList.positionViewAtIndex(at, root.viewPinMode);
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

    // select puts the selection on a message and keeps it in view: just on
    // screen by default, which is all stepping through messages needs, or
    // where mode says -- the middle, for a message searched for.
    function select(index, mode) {
        const msg = root.chatCore.messages[index];
        if (!msg)
            return;
        root.selectedId = msg.id;
        root.pinView(index, mode === undefined ? ListView.Contain : mode);
    }

    function selectPrevious() {
        const count = root.chatCore.messages.length;
        if (count === 0)
            return;
        // From nothing, start at the newest and walk back.
        root.select(root.selectedIndex < 0 ? count - 1 : Math.max(0, root.selectedIndex - 1));
    }

    function selectNext() {
        const count = root.chatCore.messages.length;
        if (count === 0 || root.selectedIndex < 0)
            return;
        root.select(Math.min(count - 1, root.selectedIndex + 1));
    }

    function clearSelection() {
        root.selectedId = "";
        // Following the newest message again if that is already where the view
        // is; otherwise it stays where it was left.
        root.viewPinId = "";
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

        const link = Links.firstWebUrl(msg.text);
        if (link !== "")
            root.chatCore.openLink(link);
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
        // A reply is a new message; whatever was being edited is set down.
        root.editTarget = null;
        root.replyTarget = msg;
    }

    function forwardSelected() {
        if (root.selectedMessage && (root.selectedMessage.text || "") !== "")
            root.forwardSource = root.selectedMessage;
    }

    // startEdit puts one of our messages in the composer to be corrected.
    function startEdit(msg) {
        if (!root.chatCore.canEdit(msg))
            return;
        root.replyTarget = null;
        root.selectedId = "";
        root.editTarget = msg;
        root.takeFocus();
    }

    // editSelected edits the selected message, or with nothing selected the
    // last one we sent -- the same thing Up does in an empty message box.
    function editSelected() {
        root.startEdit(root.selectedMessage ?? root.chatCore.lastEditable());
    }

    // reactToSelected asks which reaction to put on the selected message, or
    // with nothing selected on the newest message somebody else sent -- the
    // one a reaction is nearly always for.
    function reactToSelected() {
        if (!root.chatCore.activeSupports("reactions"))
            return;
        let target = root.selectedMessage;
        if (!target) {
            const messages = root.chatCore.messages;
            for (let i = messages.length - 1; i >= 0; i--) {
                const msg = messages[i];
                if (!msg.fromMe && msg.kind !== "system" && msg.kind !== "deleted" && msg.kind !== "unsupported") {
                    target = msg;
                    break;
                }
            }
        }
        // Not one still on its way: the service does not know it yet.
        if (target && target.kind !== "deleted" && target.kind !== "system" && target.status !== "pending" && target.status !== "failed")
            root.reactTarget = target;
    }

    // jumpTo goes to a message, when it is among those loaded: a reply's quote
    // clicked, most of all.
    function jumpTo(messageId) {
        const at = root.chatCore.indexOfMessage(messageId);
        if (at >= 0)
            root.select(at);
    }

    // ---------------------------------------------------------------- search

    function openSearch() {
        root.searching = true;
        Qt.callLater(findBar.focusField);
    }

    // closeSearch puts the bar away. The message found stays selected, so
    // Ctrl+R answers it and Escape again lets it go.
    function closeSearch() {
        root.searching = false;
    }

    // jumpToHit takes the conversation to a search result and selects it:
    // straight there when it is loaded, after paging back to it when it is
    // further up, and on a page of its own when it is further back than
    // paging goes (see ChatCore.loadBackTo).
    function jumpToHit(hit) {
        if (!hit)
            return;
        const at = root.chatCore.indexOfMessage(hit.id);
        if (at >= 0) {
            root.select(at, ListView.Center);
            return;
        }

        const provider = root.chatCore.activeProvider;
        const chatId = root.chatCore.activeChatId;
        root.chatCore.loadBackTo(hit.ts || 0, reached => {
            if (provider !== root.chatCore.activeProvider || chatId !== root.chatCore.activeChatId)
                return;
            const found = root.chatCore.indexOfMessage(hit.id);
            if (found >= 0) {
                root.select(found, ListView.Center);
                return;
            }
            // Its moment is on screen and it is not: deleted since.
            if (reached)
                return;
            root._selectOnLoad = {
                "key": provider + " " + chatId,
                "id": hit.id
            };
            root.chatCore.openChatAt(provider, chatId, hit.ts || 0);
        });
    }

    // pageIfShort asks for older messages when the conversation does not fill
    // the view: with nothing to scroll, reaching the top is never something
    // the reader can do. A provider that fetches history on request makes this
    // the usual case for a conversation started not long before this device
    // was signed in.
    function pageIfShort() {
        if (root.chatCore.messages.length === 0 || !root.chatCore.canPageOnItsOwn)
            return;
        if (messageList.contentHeight <= messageList.height)
            root.chatCore.loadOlder();
    }

    Connections {
        target: root.chatCore

        // Opening, rather than the conversation changing: opening the one
        // already open -- from the launcher, or from the unread cycle landing
        // back on it -- is still an open, and still has to place the view.
        function onChatOpened(provider, chatId) {
            root.replyTarget = null;
            root.editTarget = null;
            root.reactTarget = null;
            root.selectedId = "";
            root.pendingDelete = null;

            // A search belongs to the conversation it was typed in. Opening
            // the same one again -- a result too far back, on its own page --
            // keeps it, and what it is waiting to select.
            const key = provider + " " + chatId;
            if (root._selectOnLoad && root._selectOnLoad.key !== key)
                root._selectOnLoad = null;
            if (findBar.chatKey !== key) {
                root.searching = false;
                findBar.reset();
            }

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
            root.editTarget = null;
            root.reactTarget = null;
            root.selectedId = "";
            root.pendingDelete = null;
            if (findBar.chatKey !== root.chatCore.activeProvider + " " + root.chatCore.activeChatId) {
                root.searching = false;
                findBar.reset();
            }
        }

        // A page in: if it still does not fill the view, the next is asked for
        // on the reader's behalf. Once the layout has caught up, so the height
        // compared is the new one.
        function onHistoryLoaded(provider, chatId) {
            Qt.callLater(root.pageIfShort);
        }

        // An older page arriving above what was on screen needs nothing here:
        // the rows grow upwards and the reader stays on the message they were
        // reading (see _syncRows and _restoreAnchor). It used to be handled by
        // pinning the view to the old top message, which then held it there --
        // and snapped it back while a scroll was still carrying on upwards.

        function onMessagesChanged() {
            // Where the reader is, taken before the rows change under them.
            // Not while the view is pinned: then it goes where the pin says.
            const anchor = root.viewPinned ? null : root._anchor();
            root._syncRows();

            if (root._awaitingUnread && root.chatCore.messages.length > 0) {
                root._awaitingUnread = false;

                // A search result that had to be opened on a page of its own.
                const pending = root._selectOnLoad;
                root._selectOnLoad = null;
                const key = root.chatCore.activeProvider + " " + root.chatCore.activeChatId;
                const found = pending && pending.key === key ? root.chatCore.indexOfMessage(pending.id) : -1;
                if (found >= 0) {
                    root.select(found, ListView.Center);
                    return;
                }

                // Beginning, so the divider is the first thing on screen and
                // the unread messages read downwards from it. Nothing unread
                // means the newest message, as ever.
                root.pinView(root.chatCore.firstUnreadIndex);
                return;
            }

            // Following the newest message, or held on one: put it back there
            // once the burst is over. By name rather than as a closure, so a
            // burst of pushes queues one of these and not one per push.
            if (root.viewPinned) {
                Qt.callLater(root.applyPin);
                return;
            }
            if (anchor)
                root._restoreAnchor(anchor);
        }
    }

    // Shortcuts rather than Keys handlers: the composer holds real focus and
    // consumes most key events, so a handler on this scope would never see them.
    //
    // Ctrl throughout, where these were Alt: one modifier for everything the
    // conversation does is one thing to remember, and it is the one every other
    // key here already used.
    //
    // Which chords are available is not a matter of taste: the composer holds
    // focus, and a text field answers for some of them before the shortcut
    // system is asked -- Ctrl+V and Delete always, others only while there is
    // something to undo or delete. tests/tst_keys.qml is that list, checked
    // against every state a half-written message can be in.
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

    // Finding a message in this conversation. Ctrl+Shift+F because Ctrl+F was
    // forward long before there was a search to give it to. Pressed again
    // while the bar is open, it goes back to the search field.
    Shortcut {
        sequences: ["Ctrl+Shift+F"]
        enabled: !root.hasOverlay || root.searching
        onActivated: root.openSearch()
    }

    // E for edit: the selected message, or the last one we sent.
    Shortcut {
        sequences: ["Ctrl+E"]
        enabled: !root.hasOverlay && !root.isInvite && root.chatCore.activeSupports("edit")
        onActivated: root.editSelected()
    }

    // T for the reaction a message gets: the selected one, or the newest
    // somebody else sent.
    Shortcut {
        sequences: ["Ctrl+T"]
        enabled: !root.hasOverlay && root.chatCore.activeSupports("reactions")
        onActivated: root.reactToSelected()
    }

    // An emoji into the message being written. Ctrl+. as on other desktops'
    // emoji pickers, and one the text field leaves alone.
    Shortcut {
        sequences: ["Ctrl+."]
        enabled: !root.hasOverlay && !root.isInvite && composer.canSend
        onActivated: root.pickingEmoji = true
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
    // anything the conversation itself uses. Yes and no, as the buttons on the
    // bar say.
    Shortcut {
        sequences: ["Ctrl+Y"]
        enabled: root.isInvite && !root.hasOverlay
        onActivated: root.answerInvite(true)
    }

    Shortcut {
        sequences: ["Ctrl+N"]
        enabled: root.isInvite && !root.hasOverlay
        onActivated: root.answerInvite(false)
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            // Leaving an edit is the first thing Escape does: it is a mode the
            // composer is in, with somebody's draft set aside for it.
            if (root.editTarget) {
                root.editTarget = null;
                event.accepted = true;
                return;
            }
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
            // The search field answers Escape itself; this is for when the
            // keyboard has gone elsewhere with the bar still open.
            if (root.searching) {
                root.closeSearch();
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

    ChatReactionPicker {
        anchors.fill: parent
        z: 15
        visible: root.reactTarget !== null
        focus: visible
        message: root.reactTarget
        chatCore: root.chatCore

        onCancelled: root.reactTarget = null
        onPicked: key => {
            root.chatCore.react(root.reactTarget?.id ?? "", key);
            root.reactTarget = null;
        }
    }

    ChatEmojiPicker {
        anchors.fill: parent
        z: 15
        visible: root.pickingEmoji
        chatCore: root.chatCore

        onCancelled: root.pickingEmoji = false
        onPicked: emoji => {
            root.pickingEmoji = false;
            composer.insertText(emoji);
        }
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
                    imageSource: root.chat?.avatarPath ? "file://" + root.chat.avatarPath : ""
                    fallbackText: root.chatName.charAt(0).toUpperCase()
                    fallbackIcon: "person"
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 34 - Theme.spacingS
                    spacing: 0

                    Row {
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            id: nameLabel
                            width: Math.min(implicitWidth, parent.width - (lockIcon.visible ? lockIcon.width + parent.spacing : 0))
                            text: root.chatName
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        // End-to-end encrypted, when the provider says so of
                        // this conversation -- it can differ room by room.
                        DankIcon {
                            id: lockIcon
                            anchors.verticalCenter: nameLabel.verticalCenter
                            visible: (root.chat?.tags ?? []).indexOf("encrypted") !== -1
                            name: "lock"
                            size: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    // Who this is, in the service's own terms: the number or
                    // address they are reachable at, and which service it is.
                    // The same person can appear on more than one.
                    StyledText {
                        width: parent.width
                        text: {
                            // Somebody typing says more than anything else
                            // this line could, for as long as they are.
                            const typing = root.chatCore.activeTyping;
                            if (typing.length === 1)
                                return I18n.tr("%1 is typing…").arg(typing[0]);
                            if (typing.length === 2)
                                return I18n.tr("%1 and %2 are typing…").arg(typing[0]).arg(typing[1]);
                            if (typing.length > 2)
                                return I18n.tr("%1 people are typing…").arg(typing.length);

                            const parts = [];
                            const handles = root.chat?.handles ?? [];
                            for (let i = 0; i < handles.length; i++)
                                parts.push(handles[i]);

                            const provider = root.chatCore.providerById(root.chatCore.activeProvider);
                            parts.push(provider ? provider.name : root.chatCore.activeProvider);

                            if (root.chat?.isGroup)
                                parts.push(I18n.tr("Group"));

                            // Said here because it is the reason a message
                            // sits at "pending": a provider that is not
                            // connected sends nothing until it is.
                            const offline = root.providerStateText(provider);
                            if (offline !== "")
                                parts.push(offline);

                            return parts.join("  ·  ");
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.chatCore.activeTyping.length > 0 ? Theme.primary : Theme.surfaceVariantText
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
                // Rows by id, kept in step with the messages rather than
                // replaced by them -- see _syncRows.
                model: messageRows
                spacing: Theme.spacingXS

                // No animations as rows come and go. A row slid into place
                // moves everything after it for the length of the slide, which
                // is a conversation jiggling every time a message arrives or a
                // page loads.
                add: null
                remove: null
                displaced: null
                move: null

                // Chronological, top to bottom, parked at the end. An inverted
                // list renders a chronological model newest-first and makes
                // "scroll to the bottom" mean the wrong end of the history.
                verticalLayoutDirection: ListView.TopToBottom

                // The user moving the view, however they do it: dragging,
                // flicking, the wheel and the glide it leaves behind on a
                // touchpad, or the scrollbar. DankListView reports the wheel
                // only while it turns, and the scrollbar not at all, so a
                // message arriving mid-glide used to pull the view back.
                readonly property bool userMoving: messageList.isUserScrolling || messageList.isMomentumActive || messageList.moving || (messageList.ScrollBar.vertical?.pressed ?? false)

                // A column rather than the bubble alone, so the unread mark
                // can sit above the message it belongs to without the bubble
                // itself having to know anything about it.
                delegate: Column {
                    id: messageRow

                    required property string mid
                    // Unused here, but what DankListView's sweep for stale
                    // rows goes by.
                    required property int index

                    // The message, found by its id rather than by the row's
                    // place, so a row and what it shows never disagree --
                    // even for the moment between the messages changing and
                    // the rows following them.
                    readonly property int at: root.chatCore.indexOfMessage(messageRow.mid)
                    readonly property var modelData: messageRow.at >= 0 ? root.chatCore.messages[messageRow.at] : null

                    width: messageList.width
                    spacing: 0

                    // The day, above the first message of each. Times alone
                    // do not say whether "09:14" was this morning or last
                    // spring.
                    ChatDayDivider {
                        width: parent.width
                        visible: root.startsDay(messageRow.at)
                        text: visible ? root.dayLabel(messageRow.modelData?.ts ?? 0) : ""
                    }

                    ChatUnreadDivider {
                        width: parent.width
                        // Never at the very top: with nothing above it, the
                        // line says only that the conversation starts here.
                        visible: messageRow.at > 0 && messageRow.at === root.chatCore.firstUnreadIndex
                    }

                    MessageBubble {
                        chatCore: root.chatCore

                        width: parent.width
                        message: messageRow.modelData
                        selected: root.selectedId !== "" && root.selectedId === messageRow.mid
                        // Below the "New messages" line: what had not been
                        // read when the conversation was opened.
                        unread: root.chatCore.firstUnreadIndex >= 0 && messageRow.at >= root.chatCore.firstUnreadIndex
                        previousMessage: messageRow.at > 0 ? root.chatCore.messages[messageRow.at - 1] : null

                        onReplyRequested: {
                            root.editTarget = null;
                            root.replyTarget = messageRow.modelData;
                        }
                        onForwardRequested: root.forwardSource = messageRow.modelData
                        onCopyRequested: root.copyMessage(messageRow.modelData)
                        onEditRequested: root.startEdit(messageRow.modelData)
                        onReactRequested: root.reactTarget = messageRow.modelData
                        onQuoteClicked: messageId => root.jumpTo(messageId)
                        // What the button's tooltip says it does: for everyone
                        // only on your own message. Asking for everyone on
                        // somebody else's put up a confirmation for a delete
                        // the provider then refused.
                        onDeleteRequested: root.requestDelete(messageRow.modelData, (messageRow.modelData?.fromMe ?? false) && root.chatCore.activeSupports("revoke"))
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
                // they are reading. And stopping at the bottom is the user
                // having caught up, so the view follows the newest message
                // again.
                onUserMovingChanged: {
                    if (messageList.userMoving) {
                        root.viewPinned = false;
                        return;
                    }
                    if (messageList.atYEnd && messageList.count > 0) {
                        root.viewPinId = "";
                        root.viewPinned = true;
                    }
                }

                // Reaching the bottom while still moving there counts as well.
                // Only when the user did the moving: placing the view is not
                // them catching up.
                onAtYEndChanged: {
                    if (messageList.atYEnd && messageList.userMoving) {
                        root.viewPinId = "";
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

            // Over the top of the messages, so opening it moves nothing.
            ChatFindBar {
                id: findBar
                anchors.fill: parent
                z: 5
                visible: root.searching
                chatCore: root.chatCore

                onHitChosen: hit => root.jumpToHit(hit)
                onClosed: root.closeSearch()
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
            onScreen: root.onScreen
            replyTarget: root.replyTarget
            editTarget: root.editTarget

            onEditCleared: root.editTarget = null
            onEmojiRequested: root.pickingEmoji = true
            onEditLastRequested: root.startEdit(root.chatCore.lastEditable())

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
                root.selectedId = "";
                // Writing is catching up, whatever was left unread above.
                root.pinView(-1);
            }
        }
    }
}
