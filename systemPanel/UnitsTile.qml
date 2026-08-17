import QtQuick
import qs.Common

PanelTile {
    id: root

    required property var data

    readonly property bool degraded: data.systemdState !== "" && data.systemdState !== "running"

    title: "Failed Units"
    iconName: "error_outline"
    busy: !data.unitsRan
    error: data.unitsError
    empty: data.unitsRan && data.failedUnitList.length === 0
    emptyText: data.systemdState === "running" ? "System running, no failed units" : "No failed units"
    statusText: data.systemdState
    statusColor: degraded ? Theme.error : Theme.success
    footerText: "systemctl --failed"

    Repeater {
        model: root.data.failedUnitList

        TileRow {
            required property var modelData

            primary: modelData.unit
            secondary: modelData.description
            trailing: modelData.sub
            trailingSub: modelData.active
            dotColor: Theme.error
            primaryColor: Theme.error
        }
    }
}
