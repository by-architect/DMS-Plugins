import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "tmuxRunner"

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix that activates the launcher. The trailing space keeps unrelated words from matching."
        placeholder: "tmux "
        defaultValue: "tmux "
    }

    StringSetting {
        settingKey: "tmuxBin"
        label: "tmux binary"
        description: "Absolute path if 'tmux' is not on the shell's PATH."
        placeholder: "tmux"
        defaultValue: "tmux"
    }

    StringSetting {
        settingKey: "terminalBin"
        label: "Terminal"
        description: "Terminal emulator to open when attaching to or creating a session."
        placeholder: "ghostty"
        defaultValue: "ghostty"
    }

    StringSetting {
        settingKey: "terminalArgsOverride"
        label: "Terminal exec flags (optional)"
        description: "Space-separated flags placed between the terminal binary and the tmux command, e.g. '-e' or 'start --'. Leave blank to auto-detect for ghostty, kitty, alacritty, foot, wezterm, gnome-terminal, xterm, konsole, st, terminator and xfce4-terminal."
        placeholder: "-e"
        defaultValue: ""
    }
}
