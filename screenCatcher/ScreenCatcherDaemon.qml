import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Owns the centered panel window and the IPC surface. Every action is exposed
// here so it can be bound to a real keyboard shortcut through
// Settings -> Keybinds -> Add -> Spawn -> `quickshell -p <shell-path> ipc call
// screenCatcher <action>` (or `dms ipc call screenCatcher <action>` if the dms
// CLI is on PATH) — independently of whether the panel is even open.
//
// The bar widget and this daemon share the panel's open state through the
// "open" global var, so either side can open/close it.
PluginComponent {
    id: root

    PluginGlobalVar {
        id: openVar
        varName: "open"
        defaultValue: false
    }

    // A PanelWindow declared inline here never becomes a layer surface; it has
    // to be created by the loader.
    LazyLoader {
        id: panelLoader
        active: openVar.value === true

        ScreenCatcherPanelWindow {
            onCloseRequested: openVar.set(false)
        }
    }

    IpcHandler {
        target: "screenCatcher"

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
            const panel = openVar.value === true ? "open" : "closed";
            const rec = ScreenCatcherService.isRecording ? ("recording:" + ScreenCatcherService.recordingMode + ":" + ScreenCatcherService.elapsedLabel) : "idle";
            return panel + "\t" + rec;
        }

        // The stop command: works whether the panel is open, closed, or was
        // never opened this session — it only cares whether a recording is
        // actually running.
        function stop(): string {
            if (!ScreenCatcherService.isRecording)
                return "NOT_RECORDING";
            ScreenCatcherService.stopRecording();
            return "STOPPING";
        }

        function shotSelected(): string {
            ScreenCatcherService.takeScreenshotSelected();
            return "OK";
        }

        function shotFullscreen(): string {
            ScreenCatcherService.takeScreenshotFullscreen();
            return "OK";
        }

        function shotText(): string {
            ScreenCatcherService.screenshotToText();
            return "OK";
        }

        function recordFullscreen(): string {
            ScreenCatcherService.startRecording("full");
            return "OK";
        }

        function recordSelected(): string {
            ScreenCatcherService.startRecording("select");
            return "OK";
        }

        function recordGif(): string {
            ScreenCatcherService.startRecording("gif");
            return "OK";
        }

        function micToggle(): string {
            ScreenCatcherService.setMicOn(!ScreenCatcherService.micOn);
            return ScreenCatcherService.micOn ? "MIC_ON" : "MIC_OFF";
        }

        function sysAudioToggle(): string {
            ScreenCatcherService.setSysAudioOn(!ScreenCatcherService.sysAudioOn);
            return ScreenCatcherService.sysAudioOn ? "SYSAUDIO_ON" : "SYSAUDIO_OFF";
        }

        function clipboardToggle(): string {
            ScreenCatcherService.setCopyToClipboard(!ScreenCatcherService.copyToClipboard);
            return ScreenCatcherService.copyToClipboard ? "CLIPBOARD_ON" : "CLIPBOARD_OFF";
        }

        function downloadsToggle(): string {
            ScreenCatcherService.setSaveToDownloads(!ScreenCatcherService.saveToDownloads);
            return ScreenCatcherService.saveToDownloads ? "DOWNLOADS_ON" : "DOWNLOADS_OFF";
        }
    }

    Component.onCompleted: console.info("screenCatcher: daemon ready (ipc target 'screenCatcher')")
}
