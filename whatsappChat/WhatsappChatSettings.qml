import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Whatever these save is handed to the bridge in its `configure` call, and
// again on every change. The bridge never reads this file, or any other shell
// config, which is what lets it be run and debugged outside DMS.
//
// Nothing here is a credential: WhatsApp authenticates by linking a device, and
// that session lives in its own database under ~/.local/share/dms-whatsapp.
PluginSettings {
    id: root

    pluginId: "whatsappChat"

    // WhatsApp's own conversation categories.
    //
    // Listed here rather than in the shell because they are WhatsApp's idea:
    // another service has labels, or folders, or nothing at all. The shell only
    // reads the resulting hiddenTags list.
    readonly property var filterTags: [
        {
            "tag": "status",
            "label": "Statuses",
            "description": "The status updates contacts post"
        },
        {
            "tag": "channel",
            "label": "Channels",
            "description": "Channels you follow"
        },
        {
            "tag": "broadcast",
            "label": "Broadcast lists",
            "description": "Messages sent to a list rather than to you"
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
        return SettingsData.getPluginSetting("whatsappChat", "hiddenTags", []) || [];
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

        SettingsData.setPluginSetting("whatsappChat", "hiddenTags", current);
    }

    ToggleSetting {
        settingKey: "syncHistory"
        label: "Sync message history"
        description: "Pull past conversations when the device is first linked. Turning this off starts from an empty history and only shows messages that arrive from now on."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoDownloadMedia"
        label: "Download attachments automatically"
        description: "Fetch photos, video and voice notes as messages arrive, instead of when you open them. Backfilled history is always fetched on demand, so linking a device never downloads years of media at once."
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

        SettingsToggleRow {
            required property var modelData

            width: parent ? parent.width : 0
            text: "Show " + modelData.label
            description: modelData.description
            checked: root.isShown(modelData.tag)
            onToggled: checked => root.setShown(modelData.tag, checked)
        }
    }
}
