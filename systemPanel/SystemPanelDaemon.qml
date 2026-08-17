import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Owns the fullscreen window and the IPC surface. The bar widget and this
// daemon talk to each other through the shared "open" global var, so either
// side can open or close the panel.
PluginComponent {
    id: root

    property var popoutService: null

    readonly property int journalDays: pluginData.journalDays !== undefined ? pluginData.journalDays : 30
    readonly property bool autoRefresh: pluginData.autoRefresh !== undefined ? pluginData.autoRefresh : true

    PluginGlobalVar {
        id: openVar

        varName: "open"
        defaultValue: false
    }

    // A PanelWindow declared inline here would never become a layer surface;
    // it has to be created by the loader.
    LazyLoader {
        id: panelLoader

        active: openVar.value === true

        SystemPanelWindow {
            journalDays: root.journalDays
            autoRefresh: root.autoRefresh
            onCloseRequested: openVar.set(false)
        }
    }

    IpcHandler {
        target: "systemPanel"

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

    Component.onCompleted: console.info("systemPanel: daemon ready (ipc target 'systemPanel')")
}
