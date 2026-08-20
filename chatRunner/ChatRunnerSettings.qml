import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "chatRunner"

    SliderSetting {
        settingKey: "maxResults"
        label: "Maximum results"
        description: "How many conversations to list at once."
        defaultValue: 40
        minimum: 5
        maximum: 100
    }

    ToggleSetting {
        settingKey: "includeUnknown"
        label: "Include conversations with no messages"
        description: "Show contacts you have never written to, so you can start a conversation from here. Turning this off lists only chats with history."
        defaultValue: true
    }
}
