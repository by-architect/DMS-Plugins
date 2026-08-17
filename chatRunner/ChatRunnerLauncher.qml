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
// This holds no chat data of its own. Everything comes from the backend, which
// is what lets it list conversations from providers this file has never heard
// of.
Item {
    id: root

    property var pluginService: null

    // The launcher polls getItems on every keystroke, so results are cached and
    // answered synchronously; a request is fired off and the list refreshes
    // when it lands.
    property var _cache: ({})
    property string _pendingQuery: ""
    property string _lastQuery: ""

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

    function _normalize(query) {
        return (query || "").trim();
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

    // getItems answers from cache and refreshes in the background.
    function getItems(query) {
        const q = root._normalize(query);

        if (!ChatService.available)
            return root._statusItem("chat_bubble", "Chat is unavailable", "The DMS backend has no chat support, or no provider is enabled");

        if (q.length === 0) {
            // No query: the conversations with activity, most recent first.
            return root._toItems(ChatService.chats.slice(0, root.maxResults), "");
        }

        if (root._cache[q] !== undefined)
            return root._toItems(root._cache[q], q);

        root._request(q);
        return root._statusItem("search", "Searching conversations…", "Looking across every chat provider");
    }

    // _request asks the backend to rank conversations for a query.
    //
    // Uses resolve rather than a local filter so a phone number or an address
    // matches too, and so conversations that exist but have no messages yet are
    // still findable.
    function _request(query) {
        if (root._pendingQuery === query)
            return;
        root._pendingQuery = query;

        DMSService.sendRequest("chat.resolve", {
            "query": query,
            "limit": root.maxResults
        }, response => {
            root._pendingQuery = "";
            if (response.error)
                return;

            const cache = Object.assign({}, root._cache);
            cache[query] = response.result?.candidates || [];
            root._cache = cache;

            // Nudge the launcher to ask again now that there is an answer.
            if (root.pluginService)
                root.pluginService.requestLauncherUpdate();
        });
    }

    function _toItems(entries, query) {
        if (!entries || entries.length === 0) {
            return root._statusItem("search_off", query === "" ? "No conversations yet" : "No conversation matches \"" + query + "\"", "Try a name, a phone number, or an address");
        }

        const items = [];
        for (let i = 0; i < entries.length && i < root.maxResults; i++) {
            const entry = entries[i];

            // resolve returns chatId; the live chat list returns id.
            const chatId = entry.chatId || entry.id;
            const provider = entry.provider;
            const providerName = entry.providerName || root._providerName(provider);
            const name = entry.name || chatId;

            if (!root.includeUnknown && !entry.lastTs)
                continue;

            items.push({
                "id": "chatRunner:" + provider + ":" + chatId,
                "name": name,
                "icon": "material:" + (entry.isGroup ? "group" : "person"),
                // The service is part of the row, not a tooltip: it is the only
                // thing distinguishing two rows with the same name.
                "comment": root._comment(entry, providerName),
                "categories": ["Chats"],
                "keywords": root._keywords(entry),
                // Preserve the backend's ranking; the launcher's own scorer
                // would otherwise drop matches made on a phone number.
                "_preScored": 10000 - i,
                "chatProvider": provider,
                "chatId": chatId
            });
        }
        return items;
    }

    function _comment(entry, providerName) {
        const parts = [providerName];

        if (entry.unread > 0)
            parts.push(entry.unread + " unread");
        else if (!entry.lastTs)
            parts.push("no messages yet");

        return parts.join("  ·  ");
    }

    function _keywords(entry) {
        // Handles are what make a phone number or an address match once the
        // launcher applies its own filtering on top.
        return entry.handles || [];
    }

    function _providerName(providerId) {
        const provider = ChatService.providerById(providerId);
        return provider ? provider.name : providerId;
    }

    function executeItem(item) {
        if (!item || !item.chatProvider || !item.chatId)
            return;
        PopoutService.openChat(item.chatProvider, item.chatId);
    }

    // Results go stale as messages arrive, so the cache is dropped whenever the
    // conversation list changes.
    Connections {
        target: ChatService

        function onChatsChanged() {
            root._cache = ({});
        }
    }
}
