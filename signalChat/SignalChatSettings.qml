import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Whatever these save is handed to the bridge in its `configure` call, and again
// on every change. The bridge never reads this file, or any other shell config,
// which is what lets it be run and debugged outside DMS.
//
// Nothing here is a credential: Signal authenticates by linking a device, and
// that session lives in signal-cli's own store under ~/.local/share/signal-cli.
PluginSettings {
    id: root

    pluginId: "signalChat"

    // Signal's own conversation categories.
    //
    // Listed here rather than in the shell because they are Signal's idea:
    // another service has labels, or folders, or nothing at all. The shell only
    // reads the resulting hiddenTags list.
    //
    // Shorter than WhatsApp's because Signal genuinely has less to sort: no
    // channels, no broadcast lists, no statuses.
    readonly property var filterTags: [
        {
            "tag": "noteToSelf",
            "label": "Note to Self",
            "description": "The conversation with your own account"
        },
        {
            "tag": "blocked",
            "label": "Blocked contacts",
            "description": "People and groups you have blocked"
        },
        {
            "tag": "formerGroup",
            "label": "Groups you have left",
            "description": "Groups you are no longer a member of, whose history you can still read"
        },
        {
            "tag": "archived",
            "label": "Archived chats",
            "description": "Conversations you have put away"
        },
        {
            "tag": "muted",
            "label": "Muted chats",
            "description": "Conversations you have silenced"
        },
        {
            "tag": "group",
            "label": "Groups",
            "description": "Group conversations"
        }
    ]

    function hiddenTags() {
        return SettingsData.getPluginSetting("signalChat", "hiddenTags", []) || [];
    }

    function isShown(tag) {
        return hiddenTags().indexOf(tag) === -1;
    }

    function setShown(tag, shown) {
        const current = hiddenTags().slice();
        const at = current.indexOf(tag);

        if (!shown && at === -1)
            current.push(tag);
        else if (shown && at !== -1)
            current.splice(at, 1);
        else
            return;

        SettingsData.setPluginSetting("signalChat", "hiddenTags", current);
    }

    ToggleSetting {
        settingKey: "sendReadReceipts"
        label: "Send read receipts"
        description: "Let people see when you have read their message. Turning this off still clears your own unread count."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoDownloadMedia"
        label: "Download attachments automatically"
        description: "Fetch photos, video and voice notes as messages arrive, instead of when you open them."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "autoDownloadMaxMB"
        label: "Skip attachments larger than"
        description: "Anything above this is left to download when you open it."
        defaultValue: 16
        minimum: 1
        maximum: 100
        unit: " MB"
    }

    ToggleSetting {
        settingKey: "receiveStories"
        label: "Receive stories"
        description: "Signal stories are not shown in the chat window. Leaving this off tells the server not to send them at all."
        defaultValue: false
    }

    StringSetting {
        settingKey: "deviceName"
        label: "Device name"
        description: "How this machine appears under Linked devices on your phone. Takes effect the next time you link."
        defaultValue: "DankMaterialShell"
    }

    // ------------------------------------------------------------- filters

    StyledText {
        width: parent ? parent.width : 0
        topPadding: Theme.spacingM
        text: "Chat filters"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent ? parent.width : 0
        text: "What appears in the conversation list and the chat runner. Turning something off only hides it — searching still finds it, and nothing is deleted."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Repeater {
        model: root.filterTags

        DankToggle {
            required property var modelData

            width: parent ? parent.width : 0
            text: "Show " + modelData.label
            description: modelData.description
            checked: root.isShown(modelData.tag)
            onToggled: checked => root.setShown(modelData.tag, checked)
        }
    }
}
