import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "nixSearch"

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix that activates the search. The trailing space keeps words like 'nixos-rebuild' from matching."
        placeholder: "nix "
        defaultValue: "nix "
    }

    StringSetting {
        settingKey: "flakeRef"
        label: "Flake reference"
        description: "What to search. 'nixpkgs' uses your flake registry; pin it with something like 'github:NixOS/nixpkgs/nixos-25.05'."
        placeholder: "nixpkgs"
        defaultValue: "nixpkgs"
    }

    StringSetting {
        settingKey: "nixBin"
        label: "nix binary"
        description: "Absolute path if 'nix' is not on the shell's PATH, e.g. /run/current-system/sw/bin/nix."
        placeholder: "nix"
        defaultValue: "nix"
    }

    SelectionSetting {
        settingKey: "primaryAction"
        label: "Enter key action"
        description: "What happens when you pick a result. Everything else stays available on right-click."
        defaultValue: "copyAttr"
        options: [
            {
                label: "Copy attribute (firefox)",
                value: "copyAttr"
            },
            {
                label: "Copy installable (nixpkgs#firefox)",
                value: "copyInstallable"
            },
            {
                label: "Run without installing (nix run)",
                value: "run"
            },
            {
                label: "Open on search.nixos.org",
                value: "openWeb"
            }
        ]
    }

    SliderSetting {
        settingKey: "maxResults"
        label: "Result limit"
        description: "Broad queries can match hundreds of packages."
        defaultValue: 50
        minimum: 10
        maximum: 200
        leftIcon: "filter_list"
    }

    SliderSetting {
        settingKey: "debounceMs"
        label: "Typing delay"
        description: "How long to wait after the last keystroke before running nix search."
        defaultValue: 300
        minimum: 100
        maximum: 1500
        unit: "ms"
        leftIcon: "timer"
    }

    SliderSetting {
        settingKey: "minChars"
        label: "Minimum characters"
        description: "Shorter queries match far too much of nixpkgs to be useful."
        defaultValue: 2
        minimum: 1
        maximum: 5
        leftIcon: "text_fields"
    }

    SliderSetting {
        settingKey: "timeoutSeconds"
        label: "Search timeout"
        description: "The first search evaluates all of nixpkgs and can take a minute; later ones take a couple of seconds."
        defaultValue: 120
        minimum: 15
        maximum: 300
        unit: "s"
        leftIcon: "hourglass_top"
    }

    ToggleSetting {
        settingKey: "showProfileInstall"
        label: "Offer profile install"
        description: "Adds 'Install to user profile' (nix profile add) to the right-click menu. Off by default because it changes your profile."
        defaultValue: false
    }
}
