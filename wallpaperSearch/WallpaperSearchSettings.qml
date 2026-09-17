import QtQuick
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "wallpaperSearch"

    StringSetting {
        settingKey: "localPath"
        label: "Local folder"
        description: "Directory the Local tab browses for wallpapers"
        placeholder: "~/Pictures/Wallpapers"
        defaultValue: "~/Pictures/Wallpapers"
    }

    StringSetting {
        settingKey: "installLocation"
        label: "Install location"
        description: "Where Wallhaven images are saved when you apply one (Ctrl+Enter)"
        placeholder: "~/Pictures/Wallpapers/wallhaven"
        defaultValue: "~/Pictures/Wallpapers/wallhaven"
    }
}
