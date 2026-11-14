import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets

// The layer-shell window: the whole screen dimmed, with QuickNotesCard in
// the middle of it; a click outside the card closes it.
//
// Must come from a LazyLoader, never be declared inline in the
// PluginComponent: an inline PanelWindow never becomes a layer surface. The
// daemon keeps it loaded and `open` shows and hides it, so the draft in the
// field is still there the next time it opens.
PanelWindow {
    id: win

    property var service: null
    property bool open: false
    signal closeRequested

    readonly property bool keyboardReady: card.keyboardReady

    // Set only after the screen is chosen, so the window maps on the screen
    // that has focus rather than on whichever it was last on.
    property bool shown: false

    onOpenChanged: {
        if (!open) {
            shown = false;
            return;
        }
        if (typeof CompositorService.getFocusedScreen === "function") {
            const s = CompositorService.getFocusedScreen();
            if (s && s !== win.screen)
                win.screen = s;
        }
        shown = true;
        card.opened();
    }

    visible: shown
    color: "transparent"

    WlrLayershell.namespace: "dms:quick-notes"
    WlrLayershell.layer: WlrLayer.Overlay

    // The shell's own focus policy: Hyprland's default configuration ignores
    // layer-shell exclusive keyboard focus and uses hyprland_focus_grab.
    WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(shown, null)

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.exclusiveZone: -1

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    DankFocusGrab {
        windows: [win]
        wanted: KeyboardFocus.wantsGrab(win.shown, null)
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha(Theme.background, 0.6)

        MouseArea {
            anchors.fill: parent
            onClicked: win.closeRequested()
        }

        QuickNotesCard {
            id: card

            anchors.centerIn: parent
            width: Math.min(760, parent.width - Theme.spacingL * 4)
            height: Math.min(parent.height - Theme.spacingL * 4, Math.max(440, parent.height * 0.7))
            service: win.service
            onCloseRequested: win.closeRequested()
        }
    }
}
