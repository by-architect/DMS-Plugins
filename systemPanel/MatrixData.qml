import QtQuick
import "matrix.js" as Matrix

// The "All machines" page's data: `matrix log <kind> --json` for each kind in
// Matrix.KINDS. matrix fans out over ssh to every host it knows and merges
// their records newest first, so one kind can take twenty seconds when a host
// is slow to answer. At most `parallel` kinds run at once, each in a
// Collector of its own, and a tile keeps its last answer while the next one
// is on its way.
Item {
    id: root

    // Records asked for per kind. Repeats are folded into one row with a
    // count, so this is history, not rows.
    property int limit: 200
    property int parallel: 3

    // kind -> { records, error, unreachable, ran, busy, atMs }
    property var results: ({})
    property var _queue: []
    property int _running: 0

    readonly property bool busy: _running > 0 || _queue.length > 0
    readonly property bool everRan: Object.keys(results).some(k => results[k].ran)
    // Every machine any kind has heard from or failed to reach.
    readonly property var hosts: {
        const out = [];
        for (const k in results) {
            const r = results[k];
            for (const h of Matrix.hostsOf(r.records || []).concat(r.unreachable || []))
                if (out.indexOf(h) < 0)
                    out.push(h);
        }
        return out.sort();
    }
    readonly property var unreachable: {
        const out = [];
        for (const k in results)
            for (const h of results[k].unreachable || [])
                if (out.indexOf(h) < 0)
                    out.push(h);
        return out.sort();
    }

    // The command: a missing matrix says so at once instead of waiting out the
    // timeout, and NO_COLOR keeps its stderr plain.
    readonly property string _script: 'command -v matrix >/dev/null 2>&1 || { echo "matrix is not installed (not on PATH)" >&2; exit 127; }; NO_COLOR=1 exec matrix log "$1" --json --limit "$2"'

    function resultFor(kind) {
        return results[kind] ?? null;
    }

    function _set(kind, patch) {
        const prev = results[kind] ?? {
            records: [],
            error: "",
            unreachable: [],
            ran: false,
            busy: false,
            atMs: 0
        };
        const next = Object.assign({}, results);
        next[kind] = Object.assign({}, prev, patch);
        results = next;
    }

    function refreshAll() {
        for (const k of Matrix.KINDS) {
            const r = results[k.kind];
            if (_queue.indexOf(k.kind) >= 0 || (r && r.busy))
                continue;
            _queue = _queue.concat([k.kind]);
        }
        _pump();
    }

    function _collector(kind) {
        for (let i = 0; i < collectors.count; i++) {
            const c = collectors.itemAt(i);
            if (c && c.kind === kind)
                return c;
        }
        return null;
    }

    function _pump() {
        while (_running < parallel && _queue.length > 0) {
            const kind = _queue[0];
            _queue = _queue.slice(1);
            const c = _collector(kind);
            if (!c || c.busy)
                continue;
            _running++;
            _set(kind, {
                busy: true
            });
            c.refresh();
        }
    }

    Repeater {
        id: collectors

        model: Matrix.KINDS

        Collector {
            required property var modelData
            readonly property string kind: modelData.kind

            // matrix waits up to five seconds per host just to connect, and a
            // big local log is read whole; a minute and a half is generous.
            timeoutMs: 90000
            command: ["sh", "-c", root._script, "matrix-log", kind, String(root.limit)]
            parse: text => Matrix.parseRecords(text)

            onUpdated: {
                root._running = Math.max(0, root._running - 1);
                const prev = root.resultFor(kind);
                root._set(kind, {
                    // A failed refresh keeps the last good answer on screen.
                    records: error ? (prev ? prev.records : []) : (result || []),
                    error: error,
                    unreachable: error ? [] : Matrix.unreachableHosts(errorOutput),
                    ran: true,
                    busy: false,
                    atMs: Date.now()
                });
                root._pump();
            }
        }
    }
}
