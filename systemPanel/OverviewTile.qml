import QtQuick
import qs.Common
import "util.js" as Util

PanelTile {
    id: root

    required property var data

    readonly property var info: data.overviewData

    title: "System Overview"
    iconName: "monitor_heart"
    busy: !data.overviewRan
    error: data.overviewError
    empty: data.overviewRan && !info
    emptyText: "No system information"
    statusText: info ? ("up " + Util.fmtDuration(info.uptimeSeconds)) : ""
    statusColor: Theme.success
    footerText: info ? ("last boot took " + info.bootTime) : ""

    TileRow {
        primary: root.info ? root.info.host : ""
        secondary: root.info ? (root.info.os + "  ·  " + root.info.arch) : ""
        trailing: "host"
        dotColor: Theme.primary
        iconName: "dns"
    }

    TileRow {
        primary: root.info ? root.info.kernel : ""
        secondary: "kernel release"
        trailing: "kernel"
        dotColor: Theme.primary
        iconName: "memory"
    }

    TileRow {
        primary: root.info ? Util.fmtDuration(root.info.uptimeSeconds) : ""
        secondary: root.info ? ("load average " + root.info.loadavg) : ""
        trailing: "uptime"
        dotColor: Theme.success
        iconName: "schedule"
    }

    TileRow {
        primary: root.data.systemdState || "unknown"
        secondary: root.data.failedUnitList.length + " failed unit(s)"
        trailing: "systemd"
        dotColor: root.data.systemdState === "running" ? Theme.success : Theme.error
        primaryColor: root.data.systemdState === "running" ? Theme.surfaceText : Theme.error
        iconName: "settings"
    }

    TileRow {
        primary: root.info ? root.info.firewall : ""
        secondary: "firewall service"
        trailing: "firewall"
        dotColor: root.info && root.info.firewall === "active" ? Theme.success : Theme.warning
        iconName: "shield"
    }

    TileRow {
        primary: root.info ? root.info.sshd : ""
        secondary: root.data.exposedPortCount + " exposed port(s)"
        trailing: "sshd"
        dotColor: root.info && root.info.sshd === "active" ? Theme.warning : Theme.surfaceVariantText
        iconName: "terminal"
    }

    TileRow {
        primary: root.data.tailscaleInfo ? (root.data.tailscaleInfo.selfIps.length ? root.data.tailscaleInfo.selfIps[0] : "no address") : "unavailable"
        secondary: root.data.tailscaleInfo ? ("tailnet " + root.data.tailscaleInfo.tailnet) : "tailscale not running"
        trailing: "tailscale"
        dotColor: root.data.tailscaleInfo && root.data.tailscaleInfo.backendState === "Running" ? Theme.success : Theme.surfaceVariantText
        iconName: "vpn_lock"
    }
}
