import QtQuick
import qs.Common

PanelTile {
    id: root

    required property var data

    title: "Listening Ports"
    iconName: "lan"
    busy: !data.portsRan
    error: data.portsError
    empty: data.portsRan && data.portList.length === 0
    emptyText: "Nothing listening"
    statusText: data.exposedPortCount > 0 ? (data.exposedPortCount + " exposed") : "loopback only"
    statusColor: data.exposedPortCount > 0 ? Theme.warning : Theme.success
    footerText: "exposed = bound to a wildcard address"

    Repeater {
        model: root.data.portList

        TileRow {
            required property var modelData

            primary: modelData.proto.toUpperCase() + "  ·  " + modelData.port + (modelData.process ? ("  ·  " + modelData.process) : "")
            secondary: "bound to " + modelData.addr
            trailing: modelData.exposed ? "exposed" : "local"
            dotColor: modelData.exposed ? Theme.warning : Theme.primary
        }
    }
}
