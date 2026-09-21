pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Services

// The line stack for one screen. The surface always spans the configured
// maximum width so lines of different lengths can sit inside it without the
// window resizing under the cursor; `mask` then hands every pixel that is not
// an actual line back to whatever is underneath, so the empty half of the
// stack stays click-through.
PanelWindow {
    id: win

    property var modelData: null
    required property var host

    screen: modelData

    readonly property bool isBottom: win.host.position.indexOf("bottom") === 0
    readonly property string side: {
        const pos = win.host.position;
        if (pos.indexOf("-right") !== -1)
            return "right";
        if (pos.indexOf("-left") !== -1)
            return "left";
        return "center";
    }

    readonly property real maxLineWidth: Math.max(160, Math.round((screen ? screen.width : 1920) * win.host.widthPercent / 100))

    // Newest last while the stack grows upward from a bottom anchor (the
    // Minecraft chat direction), newest first when it hangs from the top.
    readonly property var lines: {
        const all = NotificationService.visibleNotifications.filter(w => w && w.popup);
        const trimmed = all.slice(Math.max(0, all.length - win.host.maxLines));
        return win.isBottom ? trimmed : trimmed.slice().reverse();
    }

    readonly property bool onSelectedScreen: {
        if (win.host.monitors !== "focused")
            return true;
        if (!win.host.focusedScreenName || !win.screen)
            return true;
        return win.host.focusedScreenName === win.screen.name;
    }

    visible: lines.length > 0 && onSelectedScreen
    color: "transparent"

    WlrLayershell.namespace: "dms:notification-line"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Sit inside whatever the bar and other exclusive surfaces have reserved,
    // without reserving anything itself -- a stack that grows and shrinks
    // every few seconds must never push the rest of the shell around.
    exclusionMode: ExclusionMode.Normal
    WlrLayershell.exclusiveZone: 0

    anchors.bottom: win.isBottom
    anchors.top: !win.isBottom
    anchors.left: win.side === "left"
    anchors.right: win.side === "right"

    margins {
        bottom: win.isBottom ? win.host.marginV : 0
        top: win.isBottom ? 0 : win.host.marginV
        left: win.side === "left" ? win.host.marginH : 0
        right: win.side === "right" ? win.host.marginH : 0
    }

    // A stack taller than the screen would be clamped by the compositor from
    // whichever end it likes. Capping it here, with the column pinned to the
    // anchored edge, means the overflow is always the oldest lines.
    readonly property real maxStackHeight: Math.max(64, (screen ? screen.height : 1080) - win.host.marginV * 2)

    implicitWidth: win.maxLineWidth
    implicitHeight: Math.max(1, Math.min(stack.implicitHeight, win.maxStackHeight))

    // Repeater.itemAt() is a plain function call, so the mask bindings below
    // need something that changes when the set of rows does.
    property int maskRevision: 0

    // One mask slot per possible line -- `maxLines` is capped at twelve, and a
    // slot with no row behind it masks nothing.
    function hitAt(index) {
        win.maskRevision;
        if (index >= rowRepeater.count)
            return null;
        const row = rowRepeater.itemAt(index);
        return row ? row.hitItem : null;
    }

    mask: Region {
        Region {
            item: win.hitAt(0)
        }
        Region {
            item: win.hitAt(1)
        }
        Region {
            item: win.hitAt(2)
        }
        Region {
            item: win.hitAt(3)
        }
        Region {
            item: win.hitAt(4)
        }
        Region {
            item: win.hitAt(5)
        }
        Region {
            item: win.hitAt(6)
        }
        Region {
            item: win.hitAt(7)
        }
        Region {
            item: win.hitAt(8)
        }
        Region {
            item: win.hitAt(9)
        }
        Region {
            item: win.hitAt(10)
        }
        Region {
            item: win.hitAt(11)
        }
    }

    Column {
        id: stack

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: win.isBottom ? parent.bottom : undefined
        anchors.top: win.isBottom ? undefined : parent.top

        spacing: win.host.lineSpacing

        // Indexed rather than fed the array directly: a JS array model resets
        // the whole repeater on every change, so every line would be torn down
        // and rebuilt -- replaying its entrance animation -- each time any
        // other notification arrived or expired.
        Repeater {
            id: rowRepeater

            model: win.lines.length

            onItemAdded: win.maskRevision++
            onItemRemoved: win.maskRevision++

            delegate: NotificationLine {
                required property int index

                wrapper: win.lines[index] ?? null
                host: win.host
                maxWidth: win.maxLineWidth
                align: win.side
                width: win.maxLineWidth
            }
        }
    }
}
