import QtQuick
import qs.Common
import "util.js" as Util

// Readable error/critical journal activity, system-wide — deduplicated by
// unit+message rather than a raw journalctl dump. Deliberately distinct from
// UnitsTile's "systemctl --failed": this catches a service logging errors
// while systemd still considers it running, plus kernel/non-unit sources.
PanelTile {
    id: root

    required property var data

    readonly property var errors: data.systemErrorList || []
    readonly property int criticalCount: errors.filter(e => e.priority <= 2).length

    title: "System Errors"
    iconName: "report"
    busy: !data.systemErrorsRan
    error: data.systemErrorsError
    empty: data.systemErrorsRan && errors.length === 0
    emptyText: "No errors in the journal window"
    statusText: errors.length > 0 ? (errors.length + " in window") : "clean"
    statusColor: criticalCount > 0 ? Theme.error : (errors.length > 0 ? Theme.warning : Theme.success)
    footerText: "journalctl -p err, deduplicated"

    Repeater {
        model: root.errors

        TileRow {
            required property var modelData

            primary: modelData.unit + "  ·  " + modelData.message
            secondary: modelData.count > 1 ? "seen " + modelData.count + " times  ·  " + Util.priorityLabel(modelData.priority) : Util.priorityLabel(modelData.priority)
            trailing: Util.relTime(modelData.ts)
            trailingSub: modelData.count > 1 ? "×" + modelData.count : ""
            dotColor: modelData.priority <= 2 ? Theme.error : Theme.warning
            primaryColor: modelData.priority <= 2 ? Theme.error : Theme.surfaceText
        }
    }
}
