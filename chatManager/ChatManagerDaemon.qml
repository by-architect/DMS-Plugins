pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// The chat system's headless core.
//
// This used to be three things in the shell itself: a ChatService singleton, a
// Chats section in Settings, and a modal wired into DMSShell. None of that
// exists in stock DMS, so all of it lives here instead -- the shell needs no
// chat code at all to run this.
//
// The IpcHandler below is what replaces the shell's built-in "chats" target, so
// a compositor keybind bound to `dms ipc call chats toggle` keeps working.
PluginComponent {
    id: root

    property var popoutService: null

    readonly property alias chat: chatCore

    PluginGlobalVar {
        id: openVar

        varName: "open"
        defaultValue: false
    }

    ChatLink {
        id: link

        pluginDir: Qt.resolvedUrl(".")
    }

    ChatCore {
        id: chatCore

        link: link
        pluginData: root.pluginData
    }

    // DankModal builds its own layer surface and only loads its content when
    // shown, so it is declared here rather than wrapped in a loader.
    ChatWindow {
        id: window

        chatCore: chatCore
        popoutService: root.popoutService
    }

    // The single-conversation popout. The launcher opens this rather than the
    // full window: picking one row there means "read this conversation", and
    // the sidebar would just be the list you came from.
    ChatPopout {
        id: popout

        chatCore: chatCore
    }

    // Reached by other plugins through
    // pluginService.pluginDaemonInstances["chatManager"]. The shell used to
    // offer this on PopoutService; stock DMS has no such function, and a plugin
    // cannot add one to a shell singleton.
    function openChatPopout(provider, chatId) {
        popout.openResolved(provider, chatId);
    }

    function openChatQuery(query) {
        popout.openQuery(query);
    }

    // The window and the global var track each other: the var is what the bar
    // widget or another plugin would toggle, and the window also closes itself
    // on Escape or a click outside.
    Connections {
        target: openVar

        function onValueChanged() {
            if (openVar.value)
                window.show();
            else
                window.hide();
        }
    }

    Connections {
        target: window

        function onShouldBeVisibleChanged() {
            openVar.set(window.shouldBeVisible);
            // The reference count tells the manager someone is watching. With
            // the window closed the stream stops, so an arriving message no
            // longer wakes the UI all day for a window nobody has open.
            chatCore.refCount = window.shouldBeVisible ? 1 : 0;
        }
    }

    IpcHandler {
        target: "chats"

        function toggle(): string {
            openVar.set(!openVar.value);
            return openVar.value ? "CHATS_OPEN_SUCCESS" : "CHATS_CLOSE_SUCCESS";
        }

        function open(): string {
            openVar.set(true);
            return "CHATS_OPEN_SUCCESS";
        }

        function close(): string {
            openVar.set(false);
            return "CHATS_CLOSE_SUCCESS";
        }

        function conversation(provider: string, chatId: string): string {
            if (!chatCore.available)
                return "CHATS_UNAVAILABLE: the chat manager is not running";

            root.openChatPopout(provider, chatId);
            return "CHATS_OPEN_SUCCESS";
        }

        function status(): string {
            if (!chatCore.available)
                return "CHATS_UNAVAILABLE: the chat manager is not running";

            const enabled = chatCore.providers.filter(p => p.enabled).length;
            return `CHATS_STATUS: open=${openVar.value} providers=${chatCore.providers.length} enabled=${enabled} chats=${chatCore.chats.length}`;
        }
    }
}
