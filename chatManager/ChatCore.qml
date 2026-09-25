
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import "links.js" as Links

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

    // Where the open conversation had been read when it was opened.
    //
    // A snapshot, deliberately: opening marks the conversation read, so the
    // live value is "now" a moment later and the divider it draws would vanish
    // while the user is still looking at it.
    property real unreadMarkTs: 0

    // The conversation whose opening page is still on its way, as
    // "<provider> <chatId>", and whether that open wants an unread mark at all.
    //
    // The page answers with the read position it was fetched at, and marking
    // the conversation read waits for that answer -- so the position is always
    // the one from before this open, however long the page takes and whichever
    // load ends up fetching it.
    property string _openPending: ""
    property bool _openAtUnread: false

    // The first message the user had not seen when they opened this
    // conversation, or -1. Where the view lands, and where the divider goes.
    readonly property int firstUnreadIndex: {
        if (unreadMarkTs <= 0)
            return -1;
        for (let i = 0; i < messages.length; i++) {
            const msg = messages[i];
            if (msg.fromMe)
                continue;
            if ((msg.ts || 0) > unreadMarkTs)
                return i;
        }
        return -1;
    }

    // No messagesChanged signal is declared: `property var messages` already
    // generates one, and redeclaring it is a duplicate-signal error.
    signal historyLoaded(string provider, string chatId)
    signal sendFailed(string reason)

    // Opening a conversation, including the one already open. The view places
    // itself on this rather than on activeChatId changing, which says nothing
    // when the same conversation is opened a second time from the launcher.
    signal chatOpened(string provider, string chatId)

    readonly property var activeChat: hasActiveChat ? chatByKey(activeProvider, activeChatId) : null

    function providerById(id) {
        for (let i = 0; i < providers.length; i++) {
            if (providers[i].id === id)
                return providers[i];
        }
        return null;
    }

    // Whether a provider supports a feature. The UI hides affordances rather
    // than offering ones that will fail.
    function supports(providerId, capability) {
        const provider = providerById(providerId);
        if (!provider || !provider.capabilities)
            return false;
        return provider.capabilities.indexOf(capability) !== -1;
    }

    // The same question about the open conversation, which is what nearly every
    // caller inside the window is asking.
    function activeSupports(capability) {
        return root.supports(root.activeProvider, capability);
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

        // A first guess only, from the cached conversation list: nothing is
        // subscribed while the window is closed, so a conversation opened from
        // the launcher is read out of a list that may be hours old and will
        // happily report nothing waiting. _settleOpen replaces this with the
        // read position the page itself answers with.
        const entry = root.chatByKey(provider, chatId);
        root.unreadMarkTs = entry && (entry.unread || 0) > 0 ? (entry.readUpTo || 0) : 0;

        root._openPending = provider + " " + chatId;
        root._openAtUnread = true;

        root.activeProvider = provider;
        root.activeChatId = chatId;
        root.messages = [];
        root.hasMoreHistory = false;

        // Tell the backend what is on screen, so a message the user is already
        // looking at does not also raise a notification. Marking it read waits
        // for the page -- see _settleOpen.
        setFocus(provider, chatId);
        loadHistory(0);

        root.chatOpened(provider, chatId);
    }

    // openChatAt opens a conversation positioned around a moment in time,
    // used when jumping to a search result.
    //
    // Loads the page ending just after the target rather than the newest page,
    // so the message the user picked is actually on screen.
    function openChatAt(provider, chatId, ts) {
        if (!provider || !chatId)
            return;

        // Jumping to a search result is a deliberate destination, so no unread
        // mark: the view belongs at the message that was picked, and nothing
        // here waits for a read position it is not going to use.
        root.unreadMarkTs = 0;
        root._openPending = "";

        root.activeProvider = provider;
        root.activeChatId = chatId;
        root.messages = [];
        root.hasMoreHistory = false;

        setFocus(provider, chatId);
        loadHistory(ts > 0 ? ts + 1 : 0);
        markRead();

        root.chatOpened(provider, chatId);
    }

    function closeChat() {
        root.activeProvider = "";
        root.activeChatId = "";
        root.messages = [];
        root.hasMoreHistory = false;
        root.unreadMarkTs = 0;
        root._openPending = "";
        setFocus("", "");
    }

    // chatByKey finds a conversation in the cached list, or null.
    function chatByKey(provider, chatId) {
        for (let i = 0; i < chats.length; i++) {
            const chat = chats[i];
            if (chat.provider === provider && chat.id === chatId)
                return chat;
        }
        return null;
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

        // A page big enough to reach the unread mark, with room above it for
        // the conversation it is part of. Only ever for the newest page: paging
        // backwards is the user asking for fifty more.
        let limit = 50;
        if (!before) {
            const entry = root.chatByKey(provider, chatId);
            const unread = entry ? (entry.unread || 0) : 0;
            if (unread > 0)
                limit = Math.min(500, Math.max(limit, unread + 20));
        }

        root.link.sendRequest("chat.history", {
            "provider": provider,
            "chatId": chatId,
            "before": before || 0,
            "limit": limit
        }, response => {
            root.loadingHistory = false;

            // The user may have moved on while this was in flight. Whatever is
            // on screen now asked for a page of its own and was turned away,
            // because this one was still running -- so ask again on its behalf,
            // rather than leaving it empty until some state push comes along.
            if (provider !== root.activeProvider || chatId !== root.activeChatId) {
                if (root.hasActiveChat && root.messages.length === 0)
                    root.loadHistory(0);
                return;
            }

            if (response.error) {
                root.log.warn("failed to load history:", response.error);
                // Still an open, as far as the conversation is concerned: it is
                // on screen, so it should not stay unread because its messages
                // could not be fetched.
                root._settleOpen(provider, chatId, before, null);
                return;
            }

            // Before the messages, so the mark is in place by the time anything
            // reacts to them: the view reads it to decide where to land.
            root._settleOpen(provider, chatId, before, response.result);

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

    // _settleOpen finishes opening a conversation once its first page is here.
    //
    // Two things in one place because their order is the whole point: the page
    // reports where the conversation had been read, and only then is it marked
    // read. The other way round -- which is what marking read on open did --
    // the answer describes a conversation that was already caught up, and the
    // view has nowhere to jump to.
    //
    // A manager too old to report a read position leaves the guess made when
    // the conversation was opened, which is what this used to rely on.
    function _settleOpen(provider, chatId, before, result) {
        if (before || root._openPending !== provider + " " + chatId)
            return;
        root._openPending = "";

        const readUpTo = result ? result.readUpTo : undefined;
        if (root._openAtUnread && readUpTo !== undefined)
            root.unreadMarkTs = (result.unread || 0) > 0 ? readUpTo : 0;

        root.markRead();
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

    // openLink opens a link out of a message, if it is one worth opening.
    //
    // One door for all of them, because they all come from the same untrusted
    // place: the text somebody sent, or the preview target their message
    // carried. Handing either straight to xdg-open is handing the sender the
    // choice of which program runs on this machine, so only http and https get
    // through -- see links.js.
    function openLink(url) {
        if (!Links.isWebUrl(url)) {
            root.log.warn("not opening a link that is not http(s):", url);
            return;
        }
        Quickshell.execDetached(["xdg-open", url]);
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

    // sendTo sends into a conversation that is not the open one, and says
    // whether it worked rather than reporting it itself.
    //
    // sendText above is for the conversation on screen and takes its target
    // from the view; this is for everything that picks a destination instead --
    // forwarding, and the launcher sharing the clipboard into a chat.
    function sendTo(targetProvider, targetChatId, text, attachments, callback) {
        const files = attachments || [];
        if (!available || (!text && files.length === 0)) {
            if (callback)
                callback("nothing to send");
            return;
        }

        const params = {
            "provider": targetProvider,
            "chatId": targetChatId
        };
        if (text)
            params.text = text;
        if (files.length > 0)
            params.attachments = files;

        root.link.sendRequest("chat.send", params, response => {
            if (response.error)
                root.log.warn("send failed:", response.error);
            if (callback)
                callback(response.error || "");
        });
    }

    // forward re-sends a message's text into another conversation.
    //
    // Sent as a fresh message rather than a provider-native forward: the
    // contract has no forward verb, and every provider can send text.
    function forward(targetProvider, targetChatId, text) {
        if (!available || !text)
            return;
        root.sendTo(targetProvider, targetChatId, text, [], error => {
            if (error) {
                ToastService.showError(I18n.tr("Message not forwarded"), error);
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

    // ------------------------------------------------------------ unread

    // Where the unread cycle has got to, as "<provider> <chatId>". Kept so a
    // keybind pressed repeatedly walks the list instead of reopening whichever
    // conversation happens to be newest.
    property string _unreadCursor: ""

    // Conversations with something waiting, oldest activity first.
    //
    // Oldest first on purpose: working through a backlog means starting at the
    // one that has been waiting longest, and it makes the cycle order stable
    // while new messages arrive at the other end.
    readonly property var unreadChats: {
        const out = [];
        for (let i = 0; i < chats.length; i++) {
            const chat = chats[i];
            if ((chat.unread || 0) <= 0 || chat.archived)
                continue;
            if (isChatHidden(chat))
                continue;
            out.push(chat);
        }
        out.sort((a, b) => (a.lastTs || 0) - (b.lastTs || 0));
        return out;
    }

    readonly property int unreadChatCount: unreadChats.length

    // nextUnread picks the conversation after the last one this cycle opened,
    // wrapping at the end. Returns null when nothing is waiting.
    function nextUnread() {
        const waiting = root.unreadChats;
        if (waiting.length === 0)
            return null;

        let at = -1;
        for (let i = 0; i < waiting.length; i++) {
            if (root._unreadCursor === waiting[i].provider + " " + waiting[i].id) {
                at = i;
                break;
            }
        }

        const chat = waiting[(at + 1) % waiting.length];
        root._unreadCursor = chat.provider + " " + chat.id;
        return chat;
    }

    // cycleUnread hands the next unread conversation to its callback, after
    // refreshing what is known.
    //
    // Refreshed rather than trusted: the keybind works with the window closed,
    // and with nothing on screen the state stream is not subscribed, so what is
    // held here may be minutes old. Opening is the caller's business -- the
    // window and the launcher open a conversation in different ways.
    function cycleUnread(onPicked) {
        if (!available) {
            if (onPicked)
                onPicked(null);
            return;
        }

        root.link.sendRequest("chat.unread", null, response => {
            if (response.error) {
                root.log.warn("failed to list unread conversations:", response.error);
                if (onPicked)
                    onPicked(null);
                return;
            }

            const waiting = response.result?.chats || [];
            // Fold what came back into the cached list so the ordering and the
            // hidden-tag filtering above apply to fresh data.
            root.chats = root._mergeChats(waiting);

            if (onPicked)
                onPicked(root.nextUnread());
        });
    }

    // _mergeChats overlays a fresh set onto what is cached, so a partial answer
    // never makes conversations it did not mention disappear.
    function _mergeChats(fresh) {
        const byKey = {};
        for (let i = 0; i < fresh.length; i++)
            byKey[fresh[i].provider + " " + fresh[i].id] = fresh[i];

        const merged = [];
        for (let i = 0; i < root.chats.length; i++) {
            const chat = root.chats[i];
            const key = chat.provider + " " + chat.id;
            if (byKey[key]) {
                merged.push(byKey[key]);
                delete byKey[key];
            } else if ((chat.unread || 0) > 0) {
                // It was unread and the fresh answer does not list it, so it
                // has since been read.
                const copy = Object.assign({}, chat);
                copy.unread = 0;
                merged.push(copy);
            } else {
                merged.push(chat);
            }
        }
        for (const key in byKey)
            merged.push(byKey[key]);

        return merged;
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
