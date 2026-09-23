import QtQuick
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "mountManager"

    ToggleSetting {
        settingKey: "watchUdev"
        label: "React to plugging in"
        description: "Watch udev so a device appears the moment it is plugged in, instead of at the next re-read"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "hideWhenIdle"
        label: "Hide when nothing is removable"
        description: "Take the pill out of the bar entirely while no removable device is attached"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showLoop"
        label: "Show loop devices"
        description: "Include loopback devices — snap and AppImage mounts, and anything mounted from a file"
        defaultValue: false
    }

    SliderSetting {
        settingKey: "refreshIntervalMs"
        label: "Re-read devices"
        description: "How often to run lsblk. The list is also re-read after every action, and immediately on a udev event"
        defaultValue: 5000
        minimum: 1000
        maximum: 60000
        unit: " ms"
        leftIcon: "refresh"
    }
}
