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
        label: "Screenshots: copy to clipboard"
        description: "Put screenshots and OCR text on the clipboard when finished. Also toggleable from the panel (C)."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "saveToPictures"
        label: "Screenshots: keep the file"
        description: "Save screenshots into the screenshot folder above. Turn it off to capture straight to the clipboard without leaving a file behind. Also toggleable from the panel (P)."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "copyVideoToClipboard"
        label: "Recordings: copy to clipboard"
        description: "Put the finished recording (mp4/mkv/gif) on the clipboard so it can be pasted straight into a chat. Also toggleable from the panel (B)."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "saveToVideos"
        label: "Recordings: keep the file"
        description: "Save recordings into the recording folder above. Also toggleable from the panel (V). With both recording toggles off the file is kept anyway, rather than thrown away."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyOnComplete"
        label: "Desktop notifications"
        description: "Show a notification when a screenshot or recording finishes."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "captureDelayMs"
        label: "Delay before capturing"
        description: "How long to wait after the panel closes before the screenshot/recording starts, so the panel's close animation isn't caught in the shot. Raise it if the panel still shows up; lower it if your compositor doesn't animate layer surfaces out (on Hyprland, `layerrule = noanim, dms:screen-catcher` removes the animation entirely)."
        defaultValue: 900
        minimum: 100
        maximum: 2000
        unit: "ms"
        leftIcon: "timer"
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
        description: "Used by Record Fullscreen and Record Selected. Also switchable from the panel's format chips (3/4). GIF is not a format here — it has its own panel action, 'Record Selected as GIF' (G)."
        defaultValue: "mp4"
        options: [
            {
                label: "MP4",
                value: "mp4"
            },
            {
                label: "MKV",
                value: "mkv"
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
        description: "Frames per second for 'Record Selected as GIF' (requires ffmpeg)."
        defaultValue: 20
        minimum: 5
        maximum: 30
        unit: "fps"
        leftIcon: "gif_box"
    }

    SliderSetting {
        settingKey: "gifScale"
        label: "GIF width"
        description: "Maximum output width in pixels; height scales to match, and a selection narrower than this is never upscaled. Bigger means a much bigger file and a noticeably longer conversion."
        defaultValue: 1920
        minimum: 480
        maximum: 3840
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
