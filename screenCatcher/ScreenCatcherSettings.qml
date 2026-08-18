import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "screenCatcher"

    StyledText {
        width: parent.width
        text: "Where screenshots and recordings are saved, plus optional extras. Microphone/system-audio, format chips, and the record actions themselves live in the panel (open it with your configured shortcut)."
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "screenshotDir"
        label: "Screenshot folder"
        description: "Where screenshots are saved."
        placeholder: "~/Pictures/Screenshots"
        defaultValue: "~/Pictures/Screenshots"
    }

    StringSetting {
        settingKey: "recordingDir"
        label: "Recording folder"
        description: "Where recordings (mp4/mkv/gif) are saved."
        placeholder: "~/Videos/Recordings"
        defaultValue: "~/Videos/Recordings"
    }

    ToggleSetting {
        settingKey: "copyToClipboard"
        label: "Copy to clipboard"
        description: "Copy screenshots, OCR text, and recordings to the clipboard when finished. Also toggleable from the panel (C)."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "saveToDownloads"
        label: "Save to Downloads"
        description: "Also copy every screenshot/recording into your Downloads folder. Also toggleable from the panel (L)."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notifyOnComplete"
        label: "Desktop notifications"
        description: "Show a notification when a screenshot or recording finishes."
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "imageFormat"
        label: "Default screenshot format"
        description: "Also switchable per-shot from the panel's format chips (1/2)."
        defaultValue: "png"
        options: [
            {
                label: "PNG",
                value: "png"
            },
            {
                label: "JPEG",
                value: "jpeg"
            }
        ]
    }

    SelectionSetting {
        settingKey: "recordFormat"
        label: "Default recording format"
        description: "MP4/MKV record natively; GIF captures normally then converts (requires ffmpeg). Also switchable from the panel's format chips (3/4/5)."
        defaultValue: "mp4"
        options: [
            {
                label: "MP4",
                value: "mp4"
            },
            {
                label: "MKV",
                value: "mkv"
            },
            {
                label: "GIF",
                value: "gif"
            }
        ]
    }

    StringSetting {
        settingKey: "ocrLang"
        label: "OCR language"
        description: "Tesseract language code used by 'Screenshot to Text' (requires tesseract to be installed)."
        placeholder: "eng"
        defaultValue: "eng"
    }

    SliderSetting {
        settingKey: "gifFps"
        label: "GIF frame rate"
        description: "Frames per second when recording with the GIF format chip selected (requires ffmpeg)."
        defaultValue: 12
        minimum: 5
        maximum: 30
        unit: "fps"
        leftIcon: "gif_box"
    }

    SliderSetting {
        settingKey: "gifScale"
        label: "GIF width"
        description: "Output width in pixels; height scales to match."
        defaultValue: 480
        minimum: 240
        maximum: 960
        unit: "px"
        leftIcon: "aspect_ratio"
    }

    StringSetting {
        settingKey: "micDevice"
        label: "Microphone device (optional)"
        description: "PipeWire/PulseAudio source name. Leave empty to use the system default input."
        placeholder: ""
        defaultValue: ""
    }

    StringSetting {
        settingKey: "sysAudioDevice"
        label: "System audio device (optional)"
        description: "PipeWire/PulseAudio monitor source name. Leave empty to use the default output's monitor."
        placeholder: ""
        defaultValue: ""
    }
}
