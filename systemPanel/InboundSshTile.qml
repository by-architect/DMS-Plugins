import QtQuick
import qs.Common
import qs.Widgets
import "util.js" as Util

PanelTile {
    id: root

    required property var data

    // Connections on :22 that systemd-logind has no session for. Usually a
    // handshake in flight; worth surfacing rather than hiding.
    readonly property var untrackedConnections: {
        const hosts = data.remoteSessions.map(s => s.remoteHost);
        return data.inboundSsh.filter(c => hosts.indexOf(c.peer) === -1);
    }

    title: "Inbound SSH"
    iconName: "cloud_download"
    busy: !data.sessionsRan
    error: data.sessionsError
    empty: data.sessionsRan && data.remoteSessions.length === 0 && untrackedConnections.length === 0
    emptyText: "Nobody connected from outside"
    statusText: data.remoteSessions.length > 0 ? (data.remoteSessions.length + " connected") : "none"
    statusColor: data.remoteSessions.length > 0 ? Theme.warning : Theme.success
    footerText: "live remote sessions on this device"

    Repeater {
        model: root.data.remoteSessions

        TileRow {
            required property var modelData

            primary: modelData.user + "  ·  from " + Util.shortHost(modelData.remoteHost)
            secondary: {
                var bits = ["session " + modelData.id];
                if (modelData.service)
                    bits.push(modelData.service);
                if (modelData.tty)
                    bits.push(modelData.tty);
                bits.push(modelData.state);
                return bits.join("  ·  ");
            }
            trailing: "since " + Util.relTime(modelData.ts)
            trailingSub: Util.fmtAbs(modelData.ts)
            dotColor: modelData.active ? Theme.warning : Theme.surfaceVariantText
            iconName: "person"
        }
    }

    Repeater {
        model: root.untrackedConnections

        TileRow {
            required property var modelData

            primary: "unattributed connection  ·  " + Util.shortHost(modelData.peer)
            secondary: "established to " + modelData.localAddr + "  ·  no login session"
            trailing: "live"
            dotColor: Theme.error
            primaryColor: Theme.error
            iconName: "help"
        }
    }
}
