import QtQuick
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "processWidget"

    SliderSetting {
        settingKey: "sampleIntervalMs"
        label: "Sample every"
        description: "How often /proc/stat is read for the bar's percentage. Each reading is a few small file reads, no process. The processes are measured at the same rate, but at least two seconds apart (at most once a second while the popout is open)"
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

    SliderSetting {
        settingKey: "processAlertPercent"
        label: "Process alert at"
        description: "When one process uses more than this, the pill shows that process's number with a terminal icon instead. 100% is one whole core; it has to hold for two samples in a row. This comes first, before a busy core and the total"
        defaultValue: 90
        minimum: 10
        maximum: 800
        unit: "%"
        leftIcon: "terminal"
    }

    SliderSetting {
        settingKey: "coreAlertPercent"
        label: "Core alert at"
        description: "When one core is busier than this for two samples in a row, and no process is past its alert, the pill shows that core's number with a column icon instead"
        defaultValue: 90
        minimum: 10
        maximum: 100
        unit: "%"
        leftIcon: "view_week"
    }

    ToggleSetting {
        settingKey: "showBar"
        label: "Usage bar under the number"
        description: "A hairline along the bottom of the pill, as long as the CPU is busy"
        defaultValue: true
    }
}
