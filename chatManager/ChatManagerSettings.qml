import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Everything the chat system is configured with.
//
// This was a Chats section in the shell's own Settings before the chat system
// became a plugin. Stock DMS has no such section, so the whole thing lives here
// -- global preferences first, then a row per installed provider.
PluginSettings {
    id: root

    // The live chat core, owned by this plugin's daemon surface. Reaching it
    // this way is what lets a provider be switched on from here: the daemon is
    // the only thing holding a connection to the manager process.
    readonly property var chat: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        return instances["chatManager"]?.chat ?? null;
    }

    ToggleSetting {
        settingKey: "notificationsEnabled"
        label: "Notify for new messages"
        description: "Show a desktop notification when a message arrives"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notificationPreview"
        label: "Show message preview"
        description: "Include the message text rather than only that something arrived"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyGroups"
        label: "Notify for group conversations"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyArchived"
        label: "Notify for archived conversations"
        description: "Archiving normally means keeping a conversation out of the way"
        defaultValue: false
    }

    SliderSetting {
        settingKey: "historyRetentionDays"
        label: "Keep message history for"
        description: "Older messages are deleted from the local store. Zero keeps everything."
        defaultValue: 0
        minimum: 0
        maximum: 365
        unit: " days"
    }

    SliderSetting {
        settingKey: "mediaCacheMaxMB"
        label: "Attachment cache limit"
        description: "Downloaded attachments above this are cleared oldest first."
        defaultValue: 512
        minimum: 64
        maximum: 4096
        unit: " MB"
    }

    StyledText {
        width: parent ? parent.width : 0
        topPadding: Theme.spacingM
        text: "Providers"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent ? parent.width : 0
        visible: !root.chat || root.chat.providers.length === 0
        text: {
            if (!root.chat)
                return "The chat manager is not running. Enable this plugin and reopen settings.";
            return "No providers installed. Put one in ~/.config/DankMaterialShell/chat-providers/ and it appears here.";
        }
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Repeater {
        model: root.chat ? root.chat.providers : []

        DankToggle {
            required property var modelData

            width: parent ? parent.width : 0
            text: modelData.name || modelData.id
            description: {
                if (!modelData.enabled)
                    return "Not running";
                if (modelData.error)
                    return modelData.error;
                return modelData.state === "connected" ? "Connected" : modelData.state;
            }
            checked: modelData.enabled
            onToggled: checked => root.chat.setProviderEnabled(modelData.id, checked)
        }
    }
}
