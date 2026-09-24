import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "processRunner"

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix that activates the launcher. The trailing space keeps unrelated words from matching."
        placeholder: "kill "
        defaultValue: "kill "
    }

    SliderSetting {
        settingKey: "maxResults"
        label: "Results shown"
        description: "How many processes to list, heaviest CPU usage first."
        defaultValue: 15
        minimum: 5
        maximum: 50
        leftIcon: "format_list_numbered"
    }

    SliderSetting {
        settingKey: "hotCpuThreshold"
        label: "\"Hot\" CPU threshold"
        description: "Processes at or above this CPU% get a distinct icon so heavy hitters stand out at a glance."
        defaultValue: 50
        minimum: 10
        maximum: 90
        unit: "%"
        leftIcon: "local_fire_department"
    }

    StringSetting {
        settingKey: "psBin"
        label: "ps binary"
        description: "Absolute path if 'ps' is not on the shell's PATH."
        placeholder: "ps"
        defaultValue: "ps"
    }

    StringSetting {
        settingKey: "killBin"
        label: "kill binary"
        description: "Absolute path if 'kill' is not on the shell's PATH. Note this must be the standalone kill command, not a shell builtin."
        placeholder: "kill"
        defaultValue: "kill"
    }
}
