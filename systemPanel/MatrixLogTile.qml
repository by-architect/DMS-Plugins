import QtQuick
import qs.Common
import "matrix.js" as Matrix
import "util.js" as Util

// One `matrix log` kind, from every machine at once: the same thing happening
// again is one row with a count, and each row names the machine it came from.
PanelTile {
    id: root

    // { kind, title, icon } from Matrix.KINDS
    required property var info
    // MatrixData.resultFor(kind), or null before its first run
    property var result: null
    // "" for every machine, else one host's name
    property string hostFilter: ""
    // How many records MatrixData asks for; reaching it means there are more.
    property int limit: 0

    readonly property var records: result ? result.records : []
    readonly property var shown: hostFilter ? records.filter(r => r.host === hostFilter) : records
    readonly property var rows: Matrix.group(info.kind, shown, 80)
    readonly property var verdictInfo: Matrix.verdict(info.kind, shown, rows, limit > 0 && records.length >= limit)
    readonly property var unreachable: result ? (result.unreachable || []).filter(h => !hostFilter || h === hostFilter) : []

    function toneColor(tone) {
        switch (tone) {
        case "error":
            return Theme.error;
        case "warning":
            return Theme.warning;
        case "success":
            return Theme.success;
        default:
            return Theme.surfaceVariantText;
        }
    }

    function statusColorFor(status) {
        switch (status) {
        case "fail":
            return Theme.error;
        case "warn":
            return Theme.warning;
        case "started":
            return Theme.primary;
        default:
            return Theme.success;
        }
    }

    title: info.title
    iconName: info.icon
    busy: !result || !result.ran
    error: records.length === 0 && result && result.error ? result.error : ""
    empty: !!result && result.ran && !error && rows.length === 0
    emptyText: unreachable.length > 0 ? unreachable.join(", ") + " could not be reached" : (hostFilter ? "Nothing from " + hostFilter : "Nothing logged")
    statusText: result && result.ran ? verdictInfo.text : ""
    statusColor: toneColor(verdictInfo.tone)
    footerText: {
        const bits = [];
        if (result && result.busy && result.ran)
            bits.push("refreshing…");
        bits.push("matrix log " + info.kind);
        if (shown.length > 0)
            bits.push(shown.length + (limit > 0 && records.length >= limit ? " newest records" : (shown.length === 1 ? " record" : " records")));
        if (unreachable.length > 0)
            bits.push(unreachable.join(", ") + " unreachable");
        if (result && result.error && records.length > 0)
            bits.push("last refresh failed: " + result.error);
        return bits.join(" · ");
    }

    Repeater {
        model: root.rows

        TileRow {
            required property var modelData

            primary: modelData.primary
            secondary: modelData.secondary
            trailing: Util.relTime(modelData.ms)
            // The machine, unless only one is shown; and how often, when the
            // same thing happened more than once.
            trailingSub: [modelData.count > 1 ? "×" + modelData.count : "", root.hostFilter ? "" : modelData.host].filter(s => s.length > 0).join(" · ")
            dotColor: root.statusColorFor(modelData.status)
            primaryColor: modelData.status === "fail" ? Theme.error : Theme.surfaceText
            iconName: modelData.alert ? "priority_high" : ""
        }
    }
}
