import QtQuick
import qs.Common
import "util.js" as Util

PanelTile {
    id: root

    required property var data

    title: "Local Sessions"
    iconName: "desktop_windows"
    busy: !data.sessionsRan
    error: data.sessionsError
    empty: data.sessionsRan && data.localSessions.length === 0
    emptyText: "No local sessions"
    statusText: data.localSessions.length + " active"
    statusColor: Theme.surfaceVariantText
    footerText: "systemd-logind sessions on this seat"

    Repeater {
        model: root.data.localSessions

        TileRow {
            required property var modelData

            primary: modelData.user + "  ·  " + modelData.sessionClass + (modelData.seat ? ("  ·  " + modelData.seat) : "")
            secondary: {
                var bits = ["session " + modelData.id];
                if (modelData.type)
                    bits.push(modelData.type);
                if (modelData.tty)
                    bits.push(modelData.tty);
                if (modelData.service)
                    bits.push(modelData.service);
                return bits.join("  ·  ");
            }
            trailing: modelData.state
            trailingSub: Util.relTime(modelData.ts)
            dotColor: modelData.active ? Theme.success : Theme.surfaceVariantText
            iconName: modelData.sessionClass === "manager" ? "settings_account_box" : "person"
        }
    }
}
