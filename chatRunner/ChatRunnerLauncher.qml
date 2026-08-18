import QtQuick
import qs.Common
import qs.Services

// Every conversation, from every chat provider, in one list.
//
// Deliberately flat: WhatsApp, Signal, mail and anything else appear together,
// ranked only by how well they match. Each row states which service it is on,
// so two people with the same name -- or the same person on two services -- are
// told apart by reading the row rather than by guessing.
//
// The whole conversation list is fetched once and filtered here, rather than
// asking the backend per keystroke. The launcher calls getItems on every
// character and expects an answer immediately, so anything asynchronous shows a
// "searching" placeholder in place of results that were on screen a moment
// earlier.
Item {
    id: root

    property var pluginService: null

    // Every known conversation, including contacts with no messages yet.
    property var _allChats: []
    property bool _loading: false
    property real _loadedAt: 0

    // How long the fetched list is trusted before refreshing. Conversations
    // change as messages arrive, but not fast enough to matter while typing.
    readonly property int staleAfterMs: 15000

    readonly property int maxResults: pluginService ? pluginService.loadPluginData("chatRunner", "maxResults", 40) : 40
    readonly property bool includeUnknown: pluginService ? pluginService.loadPluginData("chatRunner", "includeUnknown", true) : true

    Component.onCompleted: refCounter.active = true

    // Keeps the chat subscription alive while the runner exists, so provider
    // and unread state are current without polling.
    Loader {
        id: refCounter
        active: false
        sourceComponent: Item {
            Ref {
                service: ChatService
            }
        }
    }

    function _statusItem(icon, name, comment) {
        return [
            {
                "id": "chatRunner:status",
                "name": name,
                "icon": "material:" + icon,
                "comment": comment,
                "categories": ["Chats"],
                "_preScored": 10000
            }
        ];
    }

    function getItems(query) {
        const q = (query || "").trim();

        if (!ChatService.available)
            return root._statusItem("chat_bubble", "Chat is unavailable", "The DMS backend has no chat support, or no provider is enabled");

        root._ensureLoaded();

        if (root._allChats.length === 0) {
            return root._loading ? root._statusItem("hourglass_empty", "Loading conversations…", "") : root._statusItem("search_off", "No conversations", "Enable a chat provider under Settings, Chats");
        }

        return root._toItems(root._filter(q), q);
    }

    // _ensureLoaded fetches the full list, including conversations with no
    // messages, so someone never written to can still be found.
    function _ensureLoaded() {
        if (root._loading)
            return;
        if (root._allChats.length > 0 && (Date.now() - root._loadedAt) < root.staleAfterMs)
            return;

        root._loading = true;
        DMSService.sendRequest("chat.chats", {
            "all": true,
            "limit": 5000
        }, response => {
            root._loading = false;
            if (response.error)
                return;

            root._allChats = response.result?.chats || [];
            root._loadedAt = Date.now();

            if (root.pluginService)
                root.pluginService.requestLauncherUpdate();
        });
    }

    // _filter ranks locally, matching the backend's own ordering: an exact
    // identifier beats a name that merely contains the same text.
    function _filter(query) {
        const scored = [];
        const q = query.toLowerCase();
        const digits = query.replace(/\D/g, "");

        for (let i = 0; i < root._allChats.length; i++) {
            const chat = root._allChats[i];

            if (!root.includeUnknown && !chat.lastTs)
                continue;

            // The same hidden-tag setting the conversation list uses, so the
            // two agree about what exists.
            if (root.isHidden(chat))
                continue;

            if (q === "") {
                // No query: recent conversations only, so the list opens on
                // what you were just doing rather than the whole address book.
                if (chat.lastTs)
                    scored.push({
                        "chat": chat,
                        "score": 1
                    });
                continue;
            }

            const score = root._score(chat, q, digits);
            if (score > 0)
                scored.push({
                    "chat": chat,
                    "score": score
                });
        }

        scored.sort((a, b) => {
            if (a.score !== b.score)
                return b.score - a.score;
            return (b.chat.lastTs || 0) - (a.chat.lastTs || 0);
        });

        return scored.slice(0, root.maxResults).map(entry => entry.chat);
    }

    // isHidden applies the shell's hidden-tag setting, so archived chats,
    // statuses and channels stay out unless the user asked for them.
    function isHidden(chat) {
        const hidden = SettingsData.chatHiddenTags || [];
        if (hidden.length === 0)
            return false;

        const tags = chat.tags || [];
        for (let i = 0; i < tags.length; i++) {
            if (hidden.indexOf(tags[i]) !== -1)
                return true;
        }
        return false;
    }

    function _score(chat, lowerQuery, digits) {
        const name = (chat.name || "").toLowerCase();

        if (chat.id === lowerQuery)
            return 90;
        if (name !== "" && name === lowerQuery)
            return 70;

        // Handles are what make a phone number or an address match; the id is
        // never picked apart, because its shape belongs to the provider.
        const handles = chat.handles || [];
        for (let i = 0; i < handles.length; i++) {
            const handle = handles[i].toLowerCase();
            if (handle === lowerQuery)
                return 80;
            if (digits.length >= 7) {
                const handleDigits = handles[i].replace(/\D/g, "");
                if (handleDigits !== "" && handleDigits.indexOf(digits) !== -1)
                    return 60;
            }
            if (handle.indexOf(lowerQuery) !== -1)
                return 50;
        }

        if (name !== "") {
            if (name.indexOf(lowerQuery) === 0)
                return 40;
            if (name.indexOf(lowerQuery) !== -1)
                return 20;
        }

        return 0;
    }

    function _toItems(entries, query) {
        if (!entries || entries.length === 0)
            return root._statusItem("search_off", query === "" ? "No conversations yet" : "No conversation matches \"" + query + "\"", "Try a name, a phone number, or an address");

        const items = [];
        for (let i = 0; i < entries.length; i++) {
            const chat = entries[i];
            const providerName = root._providerName(chat.provider);

            items.push({
                "id": "chatRunner:" + chat.provider + ":" + chat.id,
                "name": chat.name || chat.id,
                "icon": "material:" + (chat.isGroup ? "group" : "person"),
                // The service is part of the row, not a tooltip: it is the only
                // thing distinguishing two rows with the same name.
                "comment": root._comment(chat, providerName),
                "categories": ["Chats"],
                "keywords": chat.handles || [],
                // Preserve this ranking; the launcher's own scorer would
                // otherwise drop matches made on a phone number.
                "_preScored": 10000 - i,
                "chatProvider": chat.provider,
                "chatId": chat.id
            });
        }
        return items;
    }

    function _comment(chat, providerName) {
        const parts = [providerName];

        if (chat.unread > 0)
            parts.push(chat.unread + " unread");
        else if (!chat.lastTs)
            parts.push("no messages yet");

        const handles = chat.handles || [];
        if (handles.length > 0)
            parts.push(handles[0]);

        return parts.join("  ·  ");
    }

    function _providerName(providerId) {
        const provider = ChatService.providerById(providerId);
        return provider ? provider.name : providerId;
    }

    function executeItem(item) {
        if (!item || !item.chatProvider || !item.chatId)
            return;
        // The popout, not the full window: picking a row here means "read this
        // conversation", and the sidebar would just be the list you came from.
        PopoutService.openChatPopoutFor(item.chatProvider, item.chatId);
    }
}
