import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "downloadsRunner"

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix that activates the launcher. The trailing space keeps unrelated words from matching."
        placeholder: "dl "
        defaultValue: "dl "
    }

    StringSetting {
        settingKey: "folder"
        label: "Folder"
        description: "The folder to search. Empty means ~/Downloads; ~ is understood."
        placeholder: "~/Downloads"
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "depth"
        label: "Folders deep"
        description: "How far into folders inside it to look. 1 is the folder itself only."
        defaultValue: 3
        minimum: 1
        maximum: 8
        leftIcon: "account_tree"
    }

    SliderSetting {
        settingKey: "maxResults"
        label: "Results shown"
        description: "How many files to list. With nothing typed, these are the newest."
        defaultValue: 30
        minimum: 5
        maximum: 100
        leftIcon: "format_list_numbered"
    }

    ToggleSetting {
        settingKey: "showHidden"
        label: "Include hidden files"
        description: "Files and folders whose name starts with a dot"
        defaultValue: false
    }
}
