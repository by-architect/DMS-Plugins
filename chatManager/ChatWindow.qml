pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Services

// The chat window.
//
// Provider-agnostic by construction: it renders whatever the backend's store
// holds and gates its affordances on what each provider declared it can do, so
// a new chat plugin needs no changes here. See docs/CHAT-PLUGINS.md.
DankModal {
    id: chatsModal

    // The chat core, handed down from the plugin daemon. It was a shell
    // singleton before this became a plugin, which is why it used to be
    // reachable from anywhere without being passed.
    //
    // Deliberately not called "chat": several of these components already use
    // that name for the conversation being shown, which is a different thing.
    required property var chatCore

    layerNamespace: "dms:chats"

    modalWidth: 900
    modalHeight: 620
    backgroundColor: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
    cornerRadius: Theme.cornerRadius
    // Kept loaded: reopening should land back in the conversation you left,
    // and rebuilding the message list on every open is visibly slow.
    keepContentLoaded: true
    visible: false

    // While the conversation has an overlay up -- help, a delete confirmation,
    // a forward picker -- Escape belongs to that overlay. Without this the
    // whole window closes on the first press and the overlay never sees it.
    closeOnEscapeKey: !(contentLoader.item?.hasOverlay ?? false)

    function toggle() {
        if (shouldBeVisible) {
            hide();
            return;
        }
        show();
    }

    function show() {
        open();
        shouldHaveFocus = true;

        Qt.callLater(() => {
            chatsModal.chatCore.refresh();
            // Re-assert focus so the backend knows the conversation is on
            // screen again and stops notifying for it.
            if (chatsModal.chatCore.hasActiveChat) {
                chatsModal.chatCore.setFocus(chatsModal.chatCore.activeProvider, chatsModal.chatCore.activeChatId);
                chatsModal.chatCore.markRead();
            }
            contentLoader.item?.takeFocus();
        });
    }

    function hide() {
        // Tell the backend nothing is on screen, so messages notify again.
        chatsModal.chatCore.setFocus("", "");
        Qt.callLater(() => chatsModal.close());
    }

    // showChat opens straight into a conversation, for the launcher and IPC.
    function showChat(provider, chatId) {
        show();
        Qt.callLater(() => chatsModal.chatCore.openChat(provider, chatId));
    }

    onDialogClosed: {
        chatsModal.chatCore.setFocus("", "");
        // Next press of the cycle binding starts from the newest unread chat
        // rather than resuming a rotation the user has visibly finished with.
        // Nothing to reset: chat cycling was a shell service that stock
        // DMS does not have.
    }

    content: Component {
        ChatsContent {
            chatCore: chatsModal.chatCore
            onCloseRequested: chatsModal.hide()
        }
    }

    // Built with the plugin daemon rather than the shell.
    //
    // A QML singleton is not built until something references it, and until it
    // exists nothing restores the providers the user enabled -- so without this
    // chat would only reconnect once the window was opened by hand. It takes no
    // subscription: notifications are raised by the backend, so live updates
    // are only needed while the UI is actually on screen.
    //
    // Deferred behind a Loader flipped by Qt.callLater rather than referenced
    // directly, because a singleton built during shell construction initialises
    // before its own dependencies are ready.
    Loader {
        id: warmup
        active: false
        sourceComponent: Item {
            Component.onCompleted: {
                if (chatsModal.chatCore.available)
                    chatsModal.chatCore.refresh();
            }
        }
    }

    Component.onCompleted: Qt.callLater(() => warmup.active = true)
}
