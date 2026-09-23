import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Owns the fullscreen window and the IPC surface. The bar widget and this
// daemon share the "open" global var, so either side can open or close the
// panel.
PluginComponent {
    id: root

    property var popoutService: null

    PluginGlobalVar {
        id: openVar

        varName: "open"
        defaultValue: false
    }

    // The loader stays active for the plugin's lifetime; the window's own
    // `open` property (not the loader's `active`) controls visibility, so
    // the Tailscale subscription and everything else persists across opens
    // instead of being rebuilt every time.
    LazyLoader {
        id: panelLoader

        active: true

        ControlPanelWindow {
            open: openVar.value === true
            onCloseRequested: openVar.set(false)
        }
    }

    IpcHandler {
        target: "controlPanel"

        function open(): string {
            openVar.set(true);
            return "OPEN";
        }

        function close(): string {
            openVar.set(false);
            return "CLOSED";
        }

        function toggle(): string {
            const next = openVar.value !== true;
            openVar.set(next);
            return next ? "OPEN" : "CLOSED";
        }

        function status(): string {
            if (openVar.value !== true)
                return "closed";
            const item = panelLoader.item;
            const keyboard = item && item.keyboardReady ? "ready" : "not-focused";
            const search = item && item.searchFocused ? "focused" : "unfocused";
            return "open\tkeyboard=" + keyboard + "\tsearch=" + search;
        }
    }

    Component.onCompleted: console.info("controlPanel: daemon ready (ipc target 'controlPanel')")
}
