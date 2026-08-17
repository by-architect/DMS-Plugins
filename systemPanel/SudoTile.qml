import QtQuick
import qs.Common
import "util.js" as Util

PanelTile {
    id: root

    required property var data

    readonly property int failedCount: data.sudoList.filter(e => e.result === "failed").length

    title: "Privilege Escalation"
    iconName: "admin_panel_settings"
    busy: !data.sudoRan
    error: data.sudoError
    empty: data.sudoRan && data.sudoList.length === 0
    emptyText: "No sudo activity recorded"
    statusText: failedCount > 0 ? (failedCount + " denied") : (data.sudoList.length + " runs")
    statusColor: failedCount > 0 ? Theme.error : Theme.surfaceVariantText
    footerText: "sudo journal, last " + data.journalDays + " days"

    Repeater {
        model: root.data.sudoList

        TileRow {
            required property var modelData

            readonly property bool failed: modelData.result === "failed"

            primary: modelData.user + (modelData.asUser ? ("  →  " + modelData.asUser) : "") + (failed ? "  ·  DENIED" : "")
            secondary: modelData.command
            trailing: Util.relTime(modelData.ts)
            trailingSub: modelData.tty
            dotColor: failed ? Theme.error : Theme.primary
            primaryColor: failed ? Theme.error : Theme.surfaceText
        }
    }
}
