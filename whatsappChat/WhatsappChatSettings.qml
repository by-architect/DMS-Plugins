import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Whatever these save is handed to the bridge in its `configure` call, and
// again on every change. The bridge never reads this file, or any other shell
// config, which is what lets it be run and debugged outside DMS.
//
// Nothing here is a credential: WhatsApp authenticates by linking a device, and
// that session lives in its own database under ~/.local/share/dms-whatsapp.
PluginSettings {
    pluginId: "whatsappChat"

    ToggleSetting {
        settingKey: "syncHistory"
        label: "Sync message history"
        description: "Pull past conversations when the device is first linked. Turning this off starts from an empty history and only shows messages that arrive from now on."
        defaultValue: true
    }
}
