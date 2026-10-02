import QtQuick
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "processWidget"

    SliderSetting {
        settingKey: "sampleIntervalMs"
        label: "Sample every"
        description: "How often /proc/stat is read for the bar's percentage. Each reading is a few small file reads, no process. The popout's process list refreshes at the same rate, at most once a second, and only while the popout is open"
        defaultValue: 2000
        minimum: 500
        maximum: 10000
        unit: " ms"
        leftIcon: "speed"
    }

    SliderSetting {
        settingKey: "processCount"
        label: "Processes listed"
        description: "How many of the busiest processes the popout shows"
        defaultValue: 8
        minimum: 3
        maximum: 30
        unit: " rows"
        leftIcon: "format_list_numbered"
    }

    SliderSetting {
        settingKey: "warnPercent"
        label: "Warning at"
        description: "The pill turns amber from this total CPU usage up"
        defaultValue: 60
        minimum: 10
        maximum: 100
        unit: "%"
        leftIcon: "warning"
    }

    SliderSetting {
        settingKey: "critPercent"
        label: "Critical at"
        description: "The pill turns red from this total CPU usage up. Set below the warning level, it counts as equal to it"
        defaultValue: 85
        minimum: 10
        maximum: 100
        unit: "%"
        leftIcon: "error"
    }

    ToggleSetting {
        settingKey: "showBar"
        label: "Usage bar under the number"
        description: "A hairline along the bottom of the pill, as long as the CPU is busy"
        defaultValue: true
    }
}
