import QtQuick
import qs.Common
import "util.js" as Util

PanelTile {
    id: root

    required property var data

    readonly property var info: data.tailscaleInfo

    title: "Tailscale"
    iconName: "vpn_lock"
    busy: !data.tailscaleRan
    error: data.tailscaleError
    empty: data.tailscaleRan && !data.tailscaleError && data.tailscaleDevices.length === 0
    emptyText: "No devices in this tailnet"
    statusText: {
        if (!info)
            return "";
        const online = root.data.tailscaleDevices.filter(d => d.online).length;
        return online + "/" + root.data.tailscaleDevices.length + " online";
    }
    statusColor: info && info.backendState === "Running" ? Theme.success : Theme.warning
    footerText: info ? (info.backendState + (info.tailnet ? ("  ·  " + info.tailnet) : "") + (info.version ? ("  ·  v" + info.version) : "")) : ""

    Repeater {
        model: root.data.tailscaleDevices

        TileRow {
            required property var modelData

            primary: modelData.name + (modelData.isSelf ? "  ·  this device" : "") + (modelData.exitNode ? "  ·  exit node" : "")
            secondary: {
                var bits = [];
                if (modelData.ip)
                    bits.push(modelData.ip);
                if (modelData.os)
                    bits.push(modelData.os);
                if (!modelData.online && modelData.lastSeen)
                    bits.push("last seen " + Util.relTime(modelData.lastSeen));
                if (modelData.online && modelData.curAddr)
                    bits.push("direct " + modelData.curAddr);
                else if (modelData.online && modelData.relay)
                    bits.push("relay " + modelData.relay);
                return bits.join("  ·  ");
            }
            trailing: modelData.online ? "online" : "offline"
            dotColor: modelData.online ? Theme.success : Theme.surfaceVariantText
            primaryColor: modelData.isSelf ? Theme.primary : Theme.surfaceText
        }
    }
}
