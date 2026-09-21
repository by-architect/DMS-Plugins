import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "notificationLine"

    StyledText {
        width: parent.width
        text: "Placement"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    SelectionSetting {
        settingKey: "position"
        label: "Corner"
        description: "Where the stack sits. Bottom corners grow upwards, newest line last; top corners hang downwards, newest line first."
        options: [
            {
                "label": "Bottom right",
                "value": "bottom-right"
            },
            {
                "label": "Bottom left",
                "value": "bottom-left"
            },
            {
                "label": "Bottom centre",
                "value": "bottom-center"
            },
            {
                "label": "Top right",
                "value": "top-right"
            },
            {
                "label": "Top left",
                "value": "top-left"
            },
            {
                "label": "Top centre",
                "value": "top-center"
            }
        ]
        defaultValue: "bottom-right"
    }

    SelectionSetting {
        settingKey: "monitors"
        label: "Monitors"
        description: "Show every line on every screen, or only on the screen that had focus when it arrived"
        options: [
            {
                "label": "All monitors",
                "value": "all"
            },
            {
                "label": "Focused monitor",
                "value": "focused"
            }
        ]
        defaultValue: "all"
    }

    SliderSetting {
        settingKey: "marginH"
        label: "Side margin"
        description: "Gap between the stack and the screen edge it is anchored to"
        defaultValue: 12
        minimum: 0
        maximum: 120
        unit: " px"
        leftIcon: "width"
    }

    SliderSetting {
        settingKey: "marginV"
        label: "Top/bottom margin"
        description: "Gap between the stack and the top or bottom edge"
        defaultValue: 12
        minimum: 0
        maximum: 120
        unit: " px"
        leftIcon: "height"
    }

    StyledText {
        width: parent.width
        text: "Lines"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    SliderSetting {
        settingKey: "maxLines"
        label: "Lines on screen"
        description: "How many notifications may be stacked at once. Also raises the shell's own popup limit, which is four by default."
        defaultValue: 6
        minimum: 1
        maximum: 12
        leftIcon: "format_list_bulleted"
    }

    SliderSetting {
        settingKey: "widthPercent"
        label: "Maximum width"
        description: "Share of the screen a single line may occupy before its text is elided. Short notifications stay narrower than this."
        defaultValue: 50
        minimum: 15
        maximum: 100
        unit: "%"
        leftIcon: "width_normal"
    }

    SliderSetting {
        settingKey: "expandedMaxLines"
        label: "Expanded height"
        description: "Text lines shown when a notification is unfolded with the arrow"
        defaultValue: 8
        minimum: 2
        maximum: 20
        leftIcon: "unfold_more"
    }

    SliderSetting {
        settingKey: "lineSpacing"
        label: "Line spacing"
        description: "Vertical gap between stacked lines"
        defaultValue: 3
        minimum: 0
        maximum: 16
        unit: " px"
        leftIcon: "format_line_spacing"
    }

    StyledText {
        width: parent.width
        text: "Timing"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "ignoreAppTimeout"
        label: "Ignore app-supplied timeouts"
        description: "Many apps ask for their own expiry time, which is why some notifications vanish in seconds while others obey Settings \u2192 Notifications. With this on, every line uses your per-urgency timeout instead, and the plugin runs the clock itself."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "lifetime"
        label: "Line lifetime"
        description: "One duration for every line, whatever its urgency. Zero follows Settings \u2192 Notifications instead."
        defaultValue: 0
        minimum: 0
        maximum: 120
        unit: " s"
        leftIcon: "timer"
    }

    StyledText {
        width: parent.width
        text: "Appearance"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    SliderSetting {
        settingKey: "fontSize"
        label: "Text size"
        defaultValue: 13
        minimum: 8
        maximum: 28
        unit: " px"
        leftIcon: "text_fields"
    }

    SliderSetting {
        settingKey: "backgroundOpacity"
        label: "Background opacity"
        description: "How solid each line's plate is. Low values give the translucent chat-overlay look."
        defaultValue: 72
        minimum: 0
        maximum: 100
        unit: "%"
        leftIcon: "opacity"
    }

    ToggleSetting {
        settingKey: "showTime"
        label: "Show age"
        description: "Leading stamp: now, 4m, 2h"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showIcon"
        label: "Show icon"
        description: "The app icon, or the notification's own image when it has one"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showAppName"
        label: "Show app name"
        description: "The accent-coloured name in front of the title"
        defaultValue: true
    }

    StyledText {
        width: parent.width
        text: "Shell integration"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "suppressBuiltin"
        label: "Replace the built-in popups"
        description: "Takes DankMaterialShell's own notification cards off every screen so they do not double up with the lines. Turning this off puts them back exactly as they were, and so does removing the plugin."
        defaultValue: true
    }
}
