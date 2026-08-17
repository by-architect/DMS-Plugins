import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "musicRunner"

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix that activates the launcher. The trailing space keeps unrelated words from matching."
        placeholder: "mpd "
        defaultValue: "mpd "
    }

    ToggleSetting {
        settingKey: "searchSongs"
        label: "Musics"
        description: "Search song titles and artists in your MPD library."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "searchPlaylists"
        label: "Lists"
        description: "Search saved playlist names."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "searchArtists"
        label: "Artists"
        description: "Search artist names in your MPD library."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "searchAlbums"
        label: "Albums"
        description: "Search album names in your MPD library."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "searchPlaylistTracks"
        label: "Musics in Lists"
        description: "Search for songs inside your saved playlists specifically, shown as \"In: <playlist name>\". Needs to read every playlist's contents ahead of time, so it refreshes on a slower cycle (about every 30s) than the other categories."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "maxPerCategory"
        label: "Results per category"
        description: "How many matches each enabled category can contribute before the combined list is ranked and shown."
        defaultValue: 6
        minimum: 2
        maximum: 15
        leftIcon: "filter_list"
    }

    SelectionSetting {
        settingKey: "primaryAction"
        label: "Enter key action"
        description: "What happens when you pick a result. \"Play now\" clears the current queue first. Right-click always offers both, plus \"Play next\" for individual songs."
        defaultValue: "enqueue"
        options: [
            {
                label: "Enqueue (add to end of queue)",
                value: "enqueue"
            },
            {
                label: "Play now (clear queue and play)",
                value: "playNow"
            }
        ]
    }

    StringSetting {
        settingKey: "mpcBin"
        label: "mpc binary"
        description: "Absolute path if 'mpc' is not on the shell's PATH."
        placeholder: "mpc"
        defaultValue: "mpc"
    }

    StringSetting {
        settingKey: "mpdHost"
        label: "MPD host (optional)"
        description: "Leave blank to use the MPD_HOST environment variable, same as running mpc yourself."
        placeholder: "blank = use MPD_HOST"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "mpdPort"
        label: "MPD port (optional)"
        description: "Leave blank to use the MPD_PORT environment variable."
        placeholder: "blank = use MPD_PORT"
        defaultValue: ""
    }
}
