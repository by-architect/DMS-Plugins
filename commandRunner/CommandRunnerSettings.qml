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

    StyledText {
        width: parent.width
        text: "Phone"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StringSetting {
        settingKey: "phoneName"
        label: "Phone name"
        description: "Adds commands for an Android phone over adb: \"run <name> hotspot\" turns its hotspot on and connects to it, and there are screen, screenshot, photo, file, link, battery, Do Not Disturb and lock commands too. Empty: none."
        placeholder: "Logos"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "phoneAddress"
        label: "adb address"
        description: "host:port where the phone answers adb over the network (wireless debugging, or adb tcpip). When it does not answer, a phone on a USB cable is used. Empty: USB only."
        placeholder: "100.70.50.3:5555"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "phoneHotspot"
        label: "Hotspot Wi-Fi name"
        description: "The network the phone's hotspot makes. Empty: asked of the phone (needs root), else the phone name."
        placeholder: "same as the phone name"
        defaultValue: ""
    }
}
