import QtQuick
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "fileActions"

    StringSetting {
        settingKey: "watchDir"
        label: "Status directory"
        description: "Where the one-file-per-action status files are written. Empty watches both $XDG_RUNTIME_DIR/matrix/fct and .../matrix/dejavu, which is the same tool under its old name."
        placeholder: "$XDG_RUNTIME_DIR/matrix/fct"
        defaultValue: ""
    }

    ToggleSetting {
        settingKey: "hideWhenIdle"
        label: "Hide when nothing is running"
        description: "Take the pill out of the bar entirely while there is no active action, instead of showing it dimmed"
        defaultValue: false
    }

    SliderSetting {
        settingKey: "activeIntervalMs"
        label: "Refresh while active"
        description: "How often to re-read the directory while an action is running"
        defaultValue: 800
        minimum: 200
        maximum: 5000
        unit: " ms"
        leftIcon: "speed"
    }

    SliderSetting {
        settingKey: "idleIntervalMs"
        label: "Refresh while idle"
        description: "How often to look for a new action when nothing is running"
        defaultValue: 3000
        minimum: 1000
        maximum: 30000
        unit: " ms"
        leftIcon: "hourglass_empty"
    }

    SliderSetting {
        settingKey: "journalIntervalMs"
        label: "Refresh finished list"
        description: "How often to re-read the event log. It is also re-read the moment an action ends, so this is only a backstop for operations started elsewhere"
        defaultValue: 30000
        minimum: 5000
        maximum: 300000
        unit: " ms"
        leftIcon: "history_toggle_off"
    }

    SliderSetting {
        settingKey: "staleSeconds"
        label: "Stalled after"
        description: "Flag a running action whose status file has stopped changing for this long"
        defaultValue: 45
        minimum: 10
        maximum: 600
        unit: " s"
        leftIcon: "pause_circle"
    }

    SliderSetting {
        settingKey: "historyLimit"
        label: "Finished actions kept"
        description: "How many completed actions the popout lists under the running ones"
        defaultValue: 20
        minimum: 3
        maximum: 100
        unit: " rows"
        leftIcon: "history"
    }
}
