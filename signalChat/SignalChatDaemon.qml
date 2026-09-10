import QtQuick
import qs.Modules.Plugins

// Connects this provider to the chat system.
//
// The provider is a plugin in its own right so it can be installed at any time,
// independently of the chat manager. Enabling this plugin is what starts the
// bridge; disabling it stops it. Its settings stay in this plugin's own settings
// page and are handed to the manager from here.
//
// The manager supervises the bridge process itself, reading the bridge argv from
// this plugin's manifest, so there is nothing to launch here.
PluginComponent {
    id: root

    property var pluginService: null

    readonly property var chatManager: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        return instances["chatManager"] ?? null;
    }

    function _register() {
        if (!root.chatManager)
            return;
        root.chatManager.registerProvider("signalChat", root.pluginData || ({}));
    }

    // Registered again whenever the manager appears, since a chat manager that
    // loads after this plugin -- or restarts -- would otherwise never hear about
    // it. Settings changes go through the same call, because the manager keeps
    // the last settings it was given for each provider.
    //
    // Coalesced: startup sets several of these at once, and each registration is
    // a round trip that restarts the bridge.
    onChatManagerChanged: registerDebounce.restart()
    onPluginDataChanged: registerDebounce.restart()

    Component.onCompleted: registerDebounce.restart()

    Timer {
        id: registerDebounce

        interval: 250
        onTriggered: root._register()
    }
    Component.onDestruction: {
        if (root.chatManager)
            root.chatManager.unregisterProvider("signalChat");
    }
}
