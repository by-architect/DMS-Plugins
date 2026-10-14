import QtQuick
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "speedTest"

    SliderSetting {
        settingKey: "intervalMinutes"
        label: "Test every"
        description: "Minutes between automatic tests; 0 runs one only when you ask (Run now, or right-click the pill). Every test downloads and uploads for several seconds each — tens to hundreds of megabytes on a fast line — so mind metered connections. A failed test is tried again after 10 minutes"
        defaultValue: 60
        minimum: 0
        maximum: 1440
        unit: " min"
        leftIcon: "schedule"
    }

    SliderSetting {
        settingKey: "slowMbps"
        label: "Slow below"
        description: "The pill turns amber when the last download was slower than this"
        defaultValue: 10
        minimum: 0
        maximum: 1000
        unit: " Mbit/s"
        leftIcon: "speed"
    }

    SelectionSetting {
        settingKey: "pillShows"
        label: "The pill shows"
        description: "What the bar shows of the last test"
        options: [
            {
                label: "Download and upload",
                value: "both"
            },
            {
                label: "Download only",
                value: "down"
            },
            {
                label: "Download, upload and ping",
                value: "all"
            }
        ]
        defaultValue: "both"
    }

    SelectionSetting {
        settingKey: "tool"
        label: "Speed test program"
        description: "Automatic picks Ookla's speedtest when it is installed, then speedtest-cli, then librespeed-cli"
        options: [
            {
                label: "Automatic",
                value: "auto"
            },
            {
                label: "speedtest-cli",
                value: "speedtest-cli"
            },
            {
                label: "Ookla speedtest",
                value: "ookla"
            },
            {
                label: "librespeed-cli",
                value: "librespeed"
            }
        ]
        defaultValue: "auto"
    }
}
