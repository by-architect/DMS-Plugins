pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "mounts.js" as Mounts

// One reader for the whole shell: the bar pill exists once per monitor and the
// popout comes and goes, so lsblk is run here, in a singleton, and every
// surface reads the same rows off it.
//
// Two triggers, because neither alone is right: a udev stream so a stick
// plugged in appears at once, and a slow poll so a missed event (or no udev at
// all) costs seconds rather than forever.
Singleton {
    id: root

    readonly property string pluginId: "mountManager"

    // ------------------------------------------------------------ settings
    property int refreshIntervalMs: 5000
    property bool watchUdev: true
    property bool showLoop: false
    property bool hideWhenIdle: false

    readonly property string listScript: Paths.strip(Qt.resolvedUrl("./scripts/list.sh"))
    readonly property string actionScript: Paths.strip(Qt.resolvedUrl("./scripts/action.sh"))

    // --------------------------------------------------------------- state
    property var rows: []
    property var removableRows: []
    property var internalRows: []
    property var summary: ({
            total: 0,
            mounted: 0,
            removable: 0,
            removableMounted: 0,
            mountable: 0,
            locked: 0
        })
    property string error: ""
    property bool everRead: false

    // How many bar pills are reading this. A singleton outlives every one of
    // them -- it stays in the engine after the plugin is disabled or its last
    // pill removed -- so the poll and the udev stream are tied to there being
    // a reader, rather than running lsblk every few seconds, and holding a
    // udevadm child open, until the shell restarts. Each pill counts itself
    // in on creation and out on destruction.
    property int consumers: 0
    readonly property bool watching: consumers > 0

    // device path -> the verb currently running on it, so a row can show what
    // it is doing and refuse to be told twice.
    property var busy: ({})

    function isBusy(path) {
        return busy[path] !== undefined;
    }

    function busyVerb(path) {
        return busy[path] !== undefined ? busy[path] : "";
    }

    // What a row is in the middle of: its own action, or its disk's eject.
    //
    // An eject is filed under the whole disk, since it powers all of it off,
    // while a row is usually a partition on it -- so asking after the row's
    // own path alone showed nothing during an eject, and left the row's mount
    // and unmount buttons live under it, contrary to "refuse to be told twice".
    function rowBusyVerb(row) {
        if (!row)
            return "";
        if (busy[row.path] !== undefined)
            return busy[row.path];
        if (row.diskPath && busy[row.diskPath] !== undefined)
            return busy[row.diskPath];
        return "";
    }

    function isRowBusy(row) {
        return rowBusyVerb(row) !== "";
    }

    function _setBusy(path, verb) {
        const next = {};
        for (const k in busy)
            next[k] = busy[k];
        if (verb)
            next[path] = verb;
        else
            delete next[path];
        busy = next;
    }

    // ------------------------------------------------------------- reading
    function refresh() {
        if (!listProc.running)
            listProc.running = true;
    }

    Process {
        id: listProc

        command: ["sh", root.listScript]
        running: false

        stdout: StdioCollector {
            onStreamFinished: root._ingest(text || "")
        }
    }

    function _ingest(raw) {
        const parsed = Mounts.parseDevices(raw, {
            showLoop: root.showLoop
        });

        root.everRead = true;
        root.error = parsed.error;
        if (parsed.error)
            return;

        root.rows = parsed.rows;
        const grouped = Mounts.groupRows(parsed.rows);
        root.removableRows = grouped.removable;
        root.internalRows = grouped.internal;
        root.summary = Mounts.summarize(parsed.rows);
    }

    Timer {
        interval: root.refreshIntervalMs
        repeat: true
        running: root.watching
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // udev says "something about a block device changed" long before a poll
    // would notice. It is a hint, not data: every line just asks for a reread,
    // debounced because one plug-in emits a burst of them.
    Process {
        id: udevProc

        command: ["udevadm", "monitor", "--udev", "--subsystem-match=block"]
        running: root.watchUdev && root.watching

        stdout: SplitParser {
            onRead: udevDebounce.restart()
        }
    }

    Timer {
        id: udevDebounce

        interval: 400
        repeat: false
        onTriggered: root.refresh()
    }

    // ------------------------------------------------------------- actions
    Component {
        id: actionProcComponent

        Process {
            id: actionProc

            property string verb: ""
            property string target: ""
            property string label: ""

            running: false

            // The script always exits 0 and always states the outcome on its
            // first line, so there is no exit code to race against the output.
            // The id is component-scoped, so each instance hands back itself —
            // a collector is not an Item and has no `parent` to ask.
            stdout: StdioCollector {
                onStreamFinished: {
                    const lines = (text || "").split("\n");
                    const ok = lines.length > 0 && lines[0].trim() === "status:ok";
                    const message = lines.slice(1).join("\n").trim();
                    root._actionFinished(actionProc, ok, message);
                }
            }
        }
    }

    property var _pending: []

    function _run(verb, target, label) {
        if (!target || isBusy(target))
            return;
        _setBusy(target, verb);

        const proc = actionProcComponent.createObject(root, {
            verb: verb,
            target: target,
            label: label || target
        });
        if (!proc) {
            _setBusy(target, "");
            return;
        }
        proc.command = ["sh", root.actionScript, verb, target];
        _pending = _pending.concat([proc]);
        proc.running = true;
    }

    function _actionFinished(owner, ok, message) {
        if (!owner)
            return;

        const verb = owner.verb;
        const label = owner.label;
        _setBusy(owner.target, "");
        _pending = _pending.filter(p => p !== owner);

        if (ok) {
            const past = verb === "mount" ? "Mounted" : (verb === "unmount" ? "Unmounted" : "Safe to remove");
            ToastService.showInfo(past + " " + label, message);
        } else {
            const failed = verb === "mount" ? "Could not mount " : (verb === "unmount" ? "Could not unmount " : "Could not eject ");
            ToastService.showError(failed + label, message);
        }

        owner.destroy();
        Qt.callLater(root.refresh);
    }

    function mount(row) {
        if (isRowBusy(row))
            return;
        _run("mount", row.path, Mounts.titleOf(row));
    }

    function unmount(row) {
        if (isRowBusy(row))
            return;
        _run("unmount", row.path, Mounts.titleOf(row));
    }

    function eject(row) {
        if (isRowBusy(row))
            return;
        _run("eject", row.diskPath || row.path, Mounts.titleOf(row));
    }

    function openMount(row) {
        if (!row.mountpoint)
            return;
        Quickshell.execDetached(["xdg-open", row.mountpoint]);
    }

    function copyText(text, what) {
        if (!text)
            return;
        // Proc.dmsBin, not a bare "dms": the shell hands its children
        // $DMS_EXECUTABLE, but does not always have dms itself on PATH.
        Quickshell.execDetached([Proc.dmsBin, "cl", "copy", text]);
        ToastService.showInfo("Copied " + (what || "path"), text);
    }

    // ------------------------------------------------------- plugin settings
    function _loadSettings() {
        refreshIntervalMs = PluginService.loadPluginData(pluginId, "refreshIntervalMs", 5000);
        watchUdev = PluginService.loadPluginData(pluginId, "watchUdev", true);
        showLoop = PluginService.loadPluginData(pluginId, "showLoop", false);
        hideWhenIdle = PluginService.loadPluginData(pluginId, "hideWhenIdle", false);
    }

    Component.onCompleted: _loadSettings()

    Connections {
        target: PluginService

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
        }
    }

    onShowLoopChanged: Qt.callLater(root.refresh)

    IpcHandler {
        target: "mountManager"

        function status(): string {
            const lines = ["devices: " + root.rows.length + "  mounted: " + root.summary.mounted + "  removable: " + root.summary.removable + "  locked: " + root.summary.locked];
            for (let i = 0; i < root.rows.length; i++) {
                const r = root.rows[i];
                lines.push([r.path, Mounts.titleOf(r), Mounts.subtitleOf(r), Mounts.detailOf(r), r.system ? "(system)" : ""].join("\t"));
            }
            return lines.join("\n");
        }

        function refresh(): string {
            root.refresh();
            return "refreshing";
        }
    }
}
