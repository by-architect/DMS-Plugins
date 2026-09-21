
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common

// Client for the chat subsystem in the DMS backend.
//
// Everything real happens in Go: providers are external bridge processes the
// daemon supervises, and the message store, media cache and notifications all
// live there (see docs/CHAT-PLUGINS.md). This service is a view onto that --
// it holds no message state of its own beyond what is currently on screen.
//
// Refcounted rather than always-on: most users have no chat plugins installed,
// and there is no reason to hold a subscription open for them. Attach a
// Ref { service: ChatService } wherever chat data is being displayed.
Item {
    id: root

    // Set by the daemon surface: the link to the manager process, and the
    // plugin's own settings.
    required property var link
    property var pluginData: ({})

    // Stock DMS has no Log singleton -- it is an addition in the forked shell
    // this code came from -- so the plugin carries its own.
    readonly property var log: QtObject {
        function warn(...args) {
            console.warn("chatManager:", args.join(" "));
        }
        function info(...args) {
            console.log("chatManager:", args.join(" "));
        }
    }

    // Providers that have registered themselves, and the settings each supplied.
    //
    // A chat provider is a plugin of its own, so it is switched on by the shell
    // enabling that plugin rather than by a setting kept here. Its daemon
    // registers on load and unregisters on unload. Held in memory and reapplied
    // on reconnect, because the manager starts every provider stopped and has no
    // idea which ones the user has installed.
    property var registeredProviders: ({})

    function registerProvider(providerId, settings) {
        const next = Object.assign({}, root.registeredProviders);
        next[providerId] = settings || ({});
        root.registeredProviders = next;
        root._applyProvider(providerId, true, next[providerId]);
    }

    function unregisterProvider(providerId) {
        const next = Object.assign({}, root.registeredProviders);
        delete next[providerId];
        root.registeredProviders = next;
        root._applyProvider(providerId, false, null);
    }

    function _applyProvider(providerId, enabled, settings) {
        if (!available)
            return;

        root.link.sendRequest("chat.setEnabled", {
            "provider": providerId,
            "enabled": enabled,
            "settings": settings || ({})
        }, response => {
            if (response.error) {
                root.log.warn("could not", enabled ? "start" : "stop", providerId + ":", response.error);
                return;
            }
            root.refresh();
        });
    }

    function _setting(key, fallback) {
        const value = root.pluginData ? root.pluginData[key] : undefined;
        return value !== undefined ? value : fallback;
    }

    property int refCount: 0

    onRefCountChanged: {
        if (refCount > 0)
            ensureSubscription();
        else if (refCount === 0)
            root.link.setSubscribed(false);
    }

    // State is only pushed while something is watching. The shell runs all day
    // with the chat window closed, and a manager narrating every arriving
    // message to a window nobody has open is pure idle cost.
    function ensureSubscription() {
        if (refCount <= 0)
            return;
        if (!root.link.isConnected)
            return;
        root.link.setSubscribed(true);
    }

    // Whether the backend was built with chat support at all. Everything in the
    // UI hangs off this, so an older daemon degrades to hiding the feature
    // rather than erroring on every call.
    readonly property bool available: root.link.isConnected

    // Every discovered chat plugin, running or not.
    property var providers: []

    // Whether the user's enabled providers have been restored this session.
    // Guarded so a later refresh cannot restart a provider the user has since
    // switched off.
    property bool _restoredEnabled: false

    // Conversations across all providers, unread and recency ordered by the
    // backend. Never sorted here -- ordering spans providers, so it has to
    // happen where all of them are visible at once.
    property var chats: []

    // Backfill progress, keyed by provider id, present only while syncing.
    property var syncProgress: ({})

    readonly property bool syncing: Object.keys(syncProgress).length > 0

    // Whether any provider has been enabled. Distinguishes "no plugins
    // installed" from "installed but switched off" in empty states.
    readonly property bool hasEnabledProvider: providers.some(p => p.enabled)

    // Every tag any conversation carries, for the settings toggles.
    property var knownTags: []

    // Conversations after each provider's own hidden-tag setting.
    //
    // Per provider rather than global: which categories exist is a property of
    // the service, so WhatsApp decides about its statuses and channels and a
    // mail plugin decides about its labels. Applied here rather than in each
    // view so the chat list and the runner agree on what is visible.
    readonly property var visibleChats: {
        const out = [];
        for (let i = 0; i < chats.length; i++) {
            if (!isChatHidden(chats[i]))
                out.push(chats[i]);
        }
        return out;
    }

    // isChatHidden reads the hiddenTags list a provider's own settings maintain.
    function isChatHidden(chat) {
        if (!chat)
            return false;

        const hidden = SettingsData.getPluginSetting(chat.provider, "hiddenTags", []);
        if (!hidden || hidden.length === 0)
            return false;

        const tags = chat.tags || [];
        for (let t = 0; t < tags.length; t++) {
            if (hidden.indexOf(tags[t]) !== -1)
                return true;
        }
        return false;
    }

    function refreshTags() {
        if (!available)
            return;
        root.link.sendRequest("chat.tags", null, response => {
            if (!response.error)
                root.knownTags = response.result?.tags || [];
        });
    }

    readonly property int totalUnread: {
        let sum = 0;
        for (let i = 0; i < chats.length; i++) {
            if (!chats[i].archived)
                sum += chats[i].unread || 0;
        }
        return sum;
    }

    // ------------------------------------------------------------ open chat

    // The conversation currently being viewed, as "<provider> <chatId>".
    // A composite key because two providers may legitimately use the same chat
    // id, and a plain string keeps it usable as a model role.
    property string activeProvider: ""
    property string activeChatId: ""

    readonly property bool hasActiveChat: activeProvider !== "" && activeChatId !== ""

    // Messages in the open conversation, oldest first.
    property var messages: []
    property bool loadingHistory: false
    property bool hasMoreHistory: false

    // No messagesChanged signal is declared: `property var messages` already
    // generates one, and redeclaring it is a duplicate-signal error.
    signal historyLoaded(string provider, string chatId)
    signal sendFailed(string reason)

    readonly property var activeChat: {
        if (!hasActiveChat)
            return null;
        for (let i = 0; i < chats.length; i++) {
            if (chats[i].provider === activeProvider && chats[i].id === activeChatId)
                return chats[i];
        }
        return null;
    }

    function providerById(id) {
        for (let i = 0; i < providers.length; i++) {
            if (providers[i].id === id)
                return providers[i];
        }
        return null;
    }

    // Whether the open conversation's provider supports a feature. The UI hides
    // affordances rather than offering ones that will fail.
    function activeSupports(capability) {
        const provider = providerById(root.activeProvider);
        if (!provider || !provider.capabilities)
            return false;
        return provider.capabilities.indexOf(capability) !== -1;
    }

    // ------------------------------------------------------------ commands

    function refresh() {
        if (!available)
            return;
        root.link.sendRequest("chat.providers", null, response => {
            if (response.error) {
                root.log.warn("failed to list providers:", response.error);
                return;
            }
            root.providers = response.result?.providers || [];
            if (!root._restoredEnabled) {
                root._restoredEnabled = true;
                root.syncEnabledProviders();
            }
        });
        root.link.sendRequest("chat.chats", null, response => {
            if (response.error) {
                root.log.warn("failed to list chats:", response.error);
                return;
            }
            root.chats = response.result?.chats || [];
        });
        root.refreshTags();
    }

    function openChat(provider, chatId) {
        if (!provider || !chatId)
            return;

        root.activeProvider = provider;
        root.activeChatId = chatId;
        root.messages = [];
        root.hasMoreHistory = false;

        // Tell the backend what is on screen, so a message the user is already
        // looking at does not also raise a notification.
        setFocus(provider, chatId);
        loadHistory(0);
        markRead();
    }

    // openChatAt opens a conversation positioned around a moment in time,
    // used when jumping to a search result.
    //
    // Loads the page ending just after the target rather than the newest page,
    // so the message the user picked is actually on screen.
    function openChatAt(provider, chatId, ts) {
        if (!provider || !chatId)
            return;

        root.activeProvider = provider;
        root.activeChatId = chatId;
        root.messages = [];
        root.hasMoreHistory = false;

        setFocus(provider, chatId);
        loadHistory(ts > 0 ? ts + 1 : 0);
        markRead();
    }

    function closeChat() {
        root.activeProvider = "";
        root.activeChatId = "";
        root.messages = [];
        root.hasMoreHistory = false;
        setFocus("", "");
    }

    function setFocus(provider, chatId) {
        if (!available)
            return;
        root.link.sendRequest("chat.setFocus", {
            "provider": provider,
            "chatId": chatId
        }, null);
    }

    // loadHistory fetches a page ending before the given timestamp. Pass 0 for
    // the newest page.
    function loadHistory(before) {
        if (!available || !hasActiveChat)
            return;
        if (root.loadingHistory)
            return;

        const provider = root.activeProvider;
        const chatId = root.activeChatId;
        root.loadingHistory = true;

        root.link.sendRequest("chat.history", {
            "provider": provider,
            "chatId": chatId,
            "before": before || 0,
            "limit": 50
        }, response => {
            root.loadingHistory = false;

            // The user may have moved on while this was in flight.
            if (provider !== root.activeProvider || chatId !== root.activeChatId)
                return;

            if (response.error) {
                root.log.warn("failed to load history:", response.error);
                return;
            }

            const page = response.result?.messages || [];
            root.hasMoreHistory = response.result?.hasMore === true;

            if (before) {
                root.messages = page.concat(root.messages);
            } else {
                root.messages = page;
            }

            root.messagesChanged();
            root.historyLoaded(provider, chatId);
        });
    }

    // loadOlder pages backwards from the oldest message on screen.
    function loadOlder() {
        if (!hasMoreHistory || root.messages.length === 0)
            return;
        loadHistory(root.messages[0].ts);
    }

    function sendText(text, replyTo) {
        if (!available || !hasActiveChat)
            return;
        if (!text || text.length === 0)
            return;

        const params = {
            "provider": root.activeProvider,
            "chatId": root.activeChatId,
            "text": text
        };
        if (replyTo)
            params.replyTo = replyTo;

        root.link.sendRequest("chat.send", params, response => {
            if (response.error) {
                root.log.warn("send failed:", response.error);
                root.sendFailed(response.error);
                ToastService.showError(I18n.tr("Message not sent"), response.error);
                return;
            }
            // The backend has already stored the message and will push new
            // state; refreshing here would race that.
        });
    }

    function sendFiles(paths, caption) {
        if (!available || !hasActiveChat || !paths || paths.length === 0)
            return;

        const params = {
            "provider": root.activeProvider,
            "chatId": root.activeChatId,
            "attachments": paths
        };
        if (caption)
            params.text = caption;

        root.link.sendRequest("chat.send", params, response => {
            if (response.error) {
                root.log.warn("attachment send failed:", response.error);
                root.sendFailed(response.error);
                ToastService.showError(I18n.tr("Attachment not sent"), response.error);
            }
        });
    }

    // revoke deletes a message for everyone. Only offered where the provider
    // declared it can, since most services allow it only within a time window.
    function revoke(provider, chatId, messageId) {
        if (!available)
            return;
        root.link.sendRequest("chat.revoke", {
            "provider": provider,
            "chatId": chatId,
            "messageId": messageId
        }, response => {
            if (response.error) {
                root.log.warn("delete failed:", response.error);
                ToastService.showError(I18n.tr("Message not deleted"), response.error);
            }
        });
    }

    // deleteLocal removes a message from this device only.
    //
    // Always available: it touches only our own store, so it works even where a
    // provider has no notion of deleting for everyone.
    function deleteLocal(provider, chatId, messageId) {
        if (!available)
            return;
        root.link.sendRequest("chat.deleteLocal", {
            "provider": provider,
            "chatId": chatId,
            "messageId": messageId
        }, response => {
            if (response.error) {
                root.log.warn("local delete failed:", response.error);
                ToastService.showError(I18n.tr("Message not deleted"), response.error);
            }
        });
    }

    // copyFileToClipboard puts a file on the clipboard as a file, so it can be
    // pasted into anything that accepts one rather than only as a path.
    function copyFileToClipboard(path) {
        if (!path)
            return;

        // wl-copy reads the bytes and takes the mime type from the file, which
        // is what makes the paste land as an image rather than as text.
        Quickshell.execDetached(["sh", "-c", "wl-copy --type \"$(file -b --mime-type \"$1\")\" < \"$1\"", "sh", path]);
        ToastService.showInfo(I18n.tr("Attachment copied"));
    }

    // forward re-sends a message's text into another conversation.
    //
    // Sent as a fresh message rather than a provider-native forward: the
    // contract has no forward verb, and every provider can send text.
    function forward(targetProvider, targetChatId, text) {
        if (!available || !text)
            return;
        root.link.sendRequest("chat.send", {
            "provider": targetProvider,
            "chatId": targetChatId,
            "text": text
        }, response => {
            if (response.error) {
                root.log.warn("forward failed:", response.error);
                ToastService.showError(I18n.tr("Message not forwarded"), response.error);
                return;
            }
            ToastService.showInfo(I18n.tr("Message forwarded"));
        });
    }

    function markRead() {
        if (!available || !hasActiveChat)
            return;
        root.link.sendRequest("chat.markRead", {
            "provider": root.activeProvider,
            "chatId": root.activeChatId,
            "upTo": Date.now()
        }, null);
    }

    // fetchMedia downloads a deferred attachment and hands back its path.
    //
    // Media is not downloaded during history sync, so opening an image is what
    // actually fetches it -- see the mediaRef contract in docs/CHAT-PLUGINS.md.
    function fetchMedia(provider, chatId, messageId, callback) {
        if (!available)
            return;

        root.link.sendRequest("chat.fetchMedia", {
            "provider": provider,
            "chatId": chatId,
            "messageId": messageId
        }, response => {
            if (response.error) {
                root.log.warn("media fetch failed:", response.error);
                ToastService.showError(I18n.tr("Could not load attachment"), response.error);
                if (callback)
                    callback("");
                return;
            }
            if (callback)
                callback(response.result?.path || "");
        });
    }

    function search(query, callback) {
        if (!available || !query) {
            if (callback)
                callback([], []);
            return;
        }

        root.link.sendRequest("chat.search", {
            "query": query,
            "limit": 50
        }, response => {
            if (response.error) {
                root.log.warn("search failed:", response.error);
                if (callback)
                    callback([], []);
                return;
            }
            if (callback)
                callback(response.result?.messages || [], response.result?.chats || []);
        });
    }

    function setArchived(provider, chatId, archived) {
        if (!available)
            return;
        root.link.sendRequest("chat.setArchived", {
            "provider": provider,
            "chatId": chatId,
            "value": archived
        }, null);
    }

    function setMuted(provider, chatId, muted) {
        if (!available)
            return;
        root.link.sendRequest("chat.setMuted", {
            "provider": provider,
            "chatId": chatId,
            "value": muted
        }, null);
    }

    // ------------------------------------------------------------ invites

    // isInvite reports a conversation the user has been asked into and has not
    // answered yet. Providers say so with the "invite" tag -- the shell knows
    // nothing about what being invited means on any one service.
    function isInvite(chat) {
        if (!chat)
            return false;
        return (chat.tags || []).indexOf("invite") !== -1;
    }

    // answerInvite joins the conversation or turns it down.
    //
    // Declining removes it: the conversation stops existing at the provider, so
    // there is nothing left to look at and the open view has to close with it.
    function answerInvite(provider, chatId, accept) {
        if (!available)
            return;

        root.link.sendRequest(accept ? "chat.acceptInvite" : "chat.declineInvite", {
            "provider": provider,
            "chatId": chatId
        }, response => {
            if (response.error) {
                root.log.warn("invite response failed:", response.error);
                ToastService.showError(accept ? I18n.tr("Could not join") : I18n.tr("Could not decline"), response.error);
                return;
            }

            if (accept) {
                ToastService.showInfo(I18n.tr("Joined"));
                return;
            }

            ToastService.showInfo(I18n.tr("Invitation declined"));
            if (root.activeProvider === provider && root.activeChatId === chatId)
                root.closeChat();
        });
    }

    // ------------------------------------------------------------ providers

    function setProviderEnabled(providerId, enabled) {
        if (!available)
            return;

        if (enabled)
            root.registerProvider(providerId, root.registeredProviders[providerId] || ({}));
        else
            root.unregisterProvider(providerId);
    }

    // syncEnabledProviders restarts the bridges of every registered provider.
    //
    // The manager deliberately starts every provider stopped: it has no opinion
    // about which the user wants. Without this, a provider would never come back
    // after the manager restarts.
    function syncEnabledProviders() {
        if (!available)
            return;

        for (const providerId in root.registeredProviders)
            root._applyProvider(providerId, true, root.registeredProviders[providerId]);
    }

    // setProviderNotifications overrides the notification policy for one
    // provider. Only the named keys change; the backend keeps the rest.
    //
    // Held by the backend rather than in settings.json because the backend is
    // what actually decides whether to notify, and a copy in the shell would be
    // one more thing to keep in step.
    function setProviderNotifications(providerId, params) {
        if (!available)
            return;

        const request = {
            "provider": providerId
        };
        for (const key in params)
            request[key] = params[key];

        root.link.sendRequest("chat.setProviderConfig", request, response => {
            if (response.error) {
                root.log.warn("failed to set notification policy:", response.error);
                return;
            }
            root.refresh();
        });
    }

    // pushProviderSettings sends a provider's settings down to its bridge.
    //
    // Settings travel over the socket rather than the bridge reading the
    // shell's config file, which is what lets a bridge be developed and tested
    // entirely outside DMS.
    function pushProviderSettings(providerId) {
        if (!available)
            return;
        root.link.sendRequest("chat.setProviderSettings", {
            "provider": providerId,
            "settings": SettingsData.getPluginSettingsForPlugin(providerId)
        }, null);
    }

    function login(providerId) {
        if (!available)
            return;
        root.link.sendRequest("chat.login", {
            "provider": providerId
        }, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Sign-in failed"), response.error);
            }
        });
    }

    // authSubmit hands typed sign-in details to a provider that asked for them.
    //
    // The values are passed straight through to the bridge and never stored:
    // not here, not in the backend, and not in plugin settings. A password
    // exists only for the duration of this call.
    function authSubmit(providerId, values, onDone) {
        if (!available)
            return;
        root.link.sendRequest("chat.authSubmit", {
            "provider": providerId,
            "values": values
        }, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Sign-in failed"), response.error);
            }
            if (onDone)
                onDone(!response.error, response.error || "");
        });
    }

    function logout(providerId) {
        if (!available)
            return;
        root.link.sendRequest("chat.logout", {
            "provider": providerId
        }, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Sign-out failed"), response.error);
            }
        });
    }

    // purge forgets everything stored for a provider. Destructive, so callers
    // are expected to confirm first.
    function purge(providerId) {
        if (!available)
            return;
        root.link.sendRequest("chat.purge", {
            "provider": providerId
        }, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Could not clear history"), response.error);
                return;
            }
            root.refresh();
        });
    }

    function rescan() {
        if (!available)
            return;
        root.link.sendRequest("chat.rescan", null, response => {
            if (!response.error)
                root.providers = response.result?.providers || [];
        });
    }

    // pushConfig sends the user's chat preferences to the backend, which owns
    // the notification policy.
    function pushConfig() {
        if (!available)
            return;
        root.link.sendRequest("chat.setConfig", {
            "notificationsEnabled": root._setting("notificationsEnabled", true),
            "notificationPreview": root._setting("notificationPreview", true),
            "notifyGroups": root._setting("notifyGroups", true),
            "notifyArchived": root._setting("notifyArchived", false),
            "historyRetentionDays": root._setting("historyRetentionDays", 0),
            "mediaCacheMaxBytes": root._setting("mediaCacheMaxMB", 512) * 1024 * 1024
        }, null);
    }

    // ------------------------------------------------------------ wiring

    // The backend owns the notification policy, so a preference change has to
    // be pushed to it. Watched here rather than hooked in SettingsData, which
    // lives in qs.Common and must not reach into qs.Services.
    //
    // Debounced because dragging a slider would otherwise send a request per
    // pixel.
    // The manager owns the notification policy, so a preference change has to
    // be pushed to it. Settings live in this plugin now, so the whole object is
    // replaced on any change rather than arriving as one signal per field.
    //
    // Debounced because dragging a slider would otherwise send a request per
    // pixel.
    onPluginDataChanged: configDebounce.restart()

    Timer {
        id: configDebounce
        interval: 250
        onTriggered: root.pushConfig()
    }

    Connections {
        target: root.link

        function onChatStateUpdate(data) {
            if (!data)
                return;

            root.providers = data.providers || [];
            root.chats = data.chats || [];
            root.syncProgress = data.sync || ({});

            // A push means the store changed. Refresh the open conversation so
            // a new message appears without the UI polling for it.
            if (root.hasActiveChat && !root.loadingHistory)
                root.loadHistory(0);
        }

        function onIsConnectedChanged() {
            if (!root.link.isConnected) {
                root.providers = [];
                root.chats = [];
                root.syncProgress = ({});
                return;
            }

            // The manager starts every provider stopped and knows nothing about
            // the user's preferences, so a fresh connection has to be told both.
            root.ensureSubscription();
            root.pushConfig();
            root.refresh();
        }
    }
}
