import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins

// Owns the task list (QuickNotesService), the window and the IPC surface.
// Bind `dms ipc call quickNotes toggle` to a key to open the window; `add`
// puts a task in without opening anything.
//
// The settings page reaches the service through
// pluginService.pluginDaemonInstances["quickNotes"].service.
PluginComponent {
    id: root

    property var popoutService: null
    property bool open: false
    readonly property var service: serviceObj

    QuickNotesService {
        id: serviceObj
    }

    // Loaded for the plugin's whole life; the window's own `open` shows and
    // hides it, so the draft in its field survives a close.
    LazyLoader {
        id: windowLoader

        active: true

        QuickNotesWindow {
            service: serviceObj
            open: root.open
            onCloseRequested: root.open = false
        }
    }

    IpcHandler {
        target: "quickNotes"

        function open(): string {
            root.open = true;
            return "OPEN";
        }

        function close(): string {
            root.open = false;
            return "CLOSED";
        }

        function toggle(): string {
            root.open = !root.open;
            return root.open ? "OPEN" : "CLOSED";
        }

        // A task from a script or a keybind, without the window. The first
        // line is its title; "\n" in the text starts its notes.
        function add(text: string): string {
            const uid = serviceObj.add(String(text || "").replace(/\\n/g, "\n"));
            return uid ? "ADDED " + uid : "NOTHING TO ADD";
        }

        function sync(): string {
            serviceObj.syncNow();
            return "SYNCING";
        }

        // Open tasks, oldest first, one per line.
        function list(): string {
            return serviceObj.tasks.filter(t => !t.completed).sort((a, b) => a.created - b.created).map(t => t.summary).join("\n");
        }

        function status(): string {
            const item = windowLoader.item;
            const window = !root.open ? "closed" : (item && item.keyboardReady ? "open, keyboard ready" : "open, no keyboard focus");
            return serviceObj.statusText() + "\nwindow:   " + window;
        }
    }

    Component.onCompleted: console.info("quickNotes: daemon ready (ipc target 'quickNotes')")
}
