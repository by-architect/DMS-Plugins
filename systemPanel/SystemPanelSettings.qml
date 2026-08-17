import QtQuick
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "systemPanel"

    ToggleSetting {
        settingKey: "autoRefresh"
        label: "Auto refresh"
        description: "Re-run every collector every 30 seconds while the panel is open"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "journalDays"
        label: "Journal window"
        description: "How far back to read the journal for failed logins and sudo activity"
        defaultValue: 30
        minimum: 1
        maximum: 180
        unit: " days"
        leftIcon: "history"
    }
}
