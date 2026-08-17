import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "commandRunner"

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix that activates the launcher. The trailing space keeps unrelated words like 'runner' from matching."
        placeholder: "run "
        defaultValue: "run "
    }

    ListSettingWithInput {
        settingKey: "commands"
        label: "Commands"
        description: "Each command runs through a shell, so pipes, redirects and quoting all work (e.g. \"grim - | wl-copy\"). Icon accepts 'material:<name>', 'unicode:<char>', or a desktop icon theme name."
        defaultValue: []
        // Widths are literal pixels, not proportional to the panel (the
        // component doesn't support that), so they're sized to the settings
        // panel's own ceiling: min(550, window width - 32) for the column,
        // minus another 32 for the Loader's margins and 72 for the Remove
        // button's reserved footprint in the item row below.
        fields: [
            {
                id: "name",
                label: "Name",
                placeholder: "Lock screen",
                width: 110,
                required: true
            },
            {
                id: "command",
                label: "Command",
                placeholder: "loginctl lock-session",
                width: 170,
                required: true
            },
            {
                id: "icon",
                label: "Icon (optional)",
                placeholder: "material:lock",
                width: 90,
                default: "material:terminal"
            }
        ]
    }
}
