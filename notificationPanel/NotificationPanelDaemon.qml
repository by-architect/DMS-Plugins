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

    // A PanelWindow declared inline here would never become a layer surface;
    // it has to be created by the loader. The loader itself stays active for
    // the plugin's lifetime — the window's own `open` property (not the
    // loader's `active`) controls visibility, so the notification tree is
    // built once and just shown/hidden afterward, instead of being destroyed
    // and rebuilt on every open.
    LazyLoader {
        id: panelLoader

        active: true

        NotificationPanelWindow {
            open: openVar.value === true
            onCloseRequested: openVar.set(false)
        }
    }

    IpcHandler {
        target: "notificationPanel"

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
            return "open\tkeyboard=" + (item && item.keyboardReady ? "ready" : "not-focused");
        }
    }

    Component.onCompleted: console.info("notificationPanel: daemon ready (ipc target 'notificationPanel')")
}
