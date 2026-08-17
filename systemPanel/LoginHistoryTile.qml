import QtQuick
import qs.Common
import "util.js" as Util

PanelTile {
    id: root

    required property var data

    title: "Login History"
    iconName: "login"
    busy: !data.lastLoginsRan && data.loginEvents.length === 0
    error: data.loginsError
    empty: data.loginEvents.length === 0 && data.lastLoginsRan
    emptyText: "No logins recorded"
    statusText: data.failedLoginCount > 0 ? (data.failedLoginCount + " failed") : "all clean"
    statusColor: data.failedLoginCount > 0 ? Theme.error : Theme.success
    footerText: "successes from wtmp · failures from sshd journal"

    Repeater {
        model: root.data.loginEvents.slice(0, 60)

        TileRow {
            required property var modelData

            readonly property bool failed: modelData.result === "failed"

            primary: modelData.user + "  ·  " + modelData.method + (modelData.host ? ("  ·  " + Util.shortHost(modelData.host)) : "")
            secondary: {
                var bits = [];
                if (failed)
                    bits.push("failed: " + modelData.detail);
                else if (modelData.active)
                    bits.push("still logged in");
                else if (modelData.detail)
                    bits.push("session " + modelData.detail);
                if (modelData.tty)
                    bits.push(modelData.tty);
                return bits.join("  ·  ");
            }
            trailing: Util.relTime(modelData.ts)
            trailingSub: Util.fmtAbs(modelData.ts)
            dotColor: failed ? Theme.error : (modelData.active ? Theme.success : Theme.primary)
            primaryColor: failed ? Theme.error : Theme.surfaceText
        }
    }
}
