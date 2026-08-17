import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import "filters.js" as Filters

// The fullscreen surface. Must be instantiated by a LazyLoader (or
// createObject), never declared inline inside the PluginComponent — an inline
// PanelWindow never becomes a layer surface.
//
// The daemon keeps this window's LazyLoader permanently active and instead
// drives visibility through `open`. Opening/closing then only maps or unmaps
// the surface — the ~50-row notification tree stays instantiated in memory
// instead of being torn down and rebuilt from scratch on every open, which is
// what made the panel feel slow to appear.
PanelWindow {
    id: win

    readonly property string pluginId: "notificationPanel"
    readonly property int slotCount: 6

    property bool open: false

    signal closeRequested

    property var categories: []
    property string searchQuery: ""

    readonly property bool keyboardReady: rootFocus.activeFocus

    onOpenChanged: {
        if (open)
            focusAnchor.forceActiveFocus();
    }

    readonly property var searchTokens: Filters.parseFilter(searchQuery)
    readonly property var sortedItems: {
        const arr = NotificationService.historyList.slice();
        arr.sort((a, b) => b.timestamp - a.timestamp);
        return arr;
    }
    readonly property var flowItems: sortedItems.filter(it => Filters.matches(it, searchTokens))

    function loadCategories() {
        const stored = PluginService.loadPluginData(pluginId, "categories", []);
        const arr = stored.slice(0, slotCount).map(c => c ? Filters.migrateCategory(c) : null);
        while (arr.length < slotCount)
            arr.push(null);
        categories = arr;
    }

    function saveCategories() {
        PluginService.savePluginData(pluginId, "categories", categories);
    }

    function setCategory(index, category) {
        const next = categories.slice();
        next[index] = category;
        categories = next;
        saveCategories();
    }

    Component.onCompleted: loadCategories()

    visible: open
    color: "transparent"

    WlrLayershell.namespace: "dms:notification-panel"
    WlrLayershell.layer: WlrLayer.Overlay

    // Mirrors the shell's own focus policy: Hyprland's default configuration
    // ignores layer-shell exclusive keyboard focus and uses
    // hyprland_focus_grab instead. Hardcoding WlrKeyboardFocus.Exclusive would
    // silently leave the panel unable to receive Esc on Hyprland.
    WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(open, null)

    // True fullscreen: draw over the bar rather than reserving space below it.
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
        wanted: KeyboardFocus.wantsGrab(win.open, null)
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha(Theme.background, 0.985)

        FocusScope {
            id: rootFocus

            anchors.fill: parent
            focus: true

            Keys.onEscapePressed: win.closeRequested()
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Q && !searchField.field.activeFocus) {
                    win.closeRequested();
                    event.accepted = true;
                }
            }

            // A FocusScope's forceActiveFocus() backfills to whichever
            // descendant last held focus (e.g. the search field) rather than
            // focusing the scope itself. Since the window now persists across
            // close/reopen instead of being destroyed, that backfill would
            // silently reclaim the search field's cursor on every reopen.
            // Targeting this concrete leaf item instead resets the backfill
            // chain to something harmless.
            Item {
                id: focusAnchor

                width: 0
                height: 0
                focus: true
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                // ------------------------------------------------------ header
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44

                    DankIcon {
                        id: headerIcon

                        name: "notifications"
                        size: 26
                        color: Theme.primary
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        anchors.left: headerIcon.right
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        StyledText {
                            text: "Notification Panel"
                            font.pixelSize: Theme.fontSizeLarge + 2
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: win.sortedItems.length + " notification" + (win.sortedItems.length === 1 ? "" : "s") + " · " + win.categories.filter(c => c !== null).length + "/" + win.slotCount + " categories"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingM

                        StyledText {
                            text: "Esc close"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            opacity: 0.8
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        DankActionButton {
                            iconName: "close"
                            iconSize: 20
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: win.closeRequested()
                        }
                    }
                }

                // ------------------------------------------------ main content
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Theme.spacingM

                    GridLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        columns: 2
                        rows: 3
                        columnSpacing: Theme.spacingM
                        rowSpacing: Theme.spacingM

                        Repeater {
                            model: win.slotCount

                            CategoryTile {
                                required property int index

                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                category: win.categories[index] ?? null
                                allItems: win.sortedItems
                                searchQuery: win.searchQuery
                                onSaveRequested: category => win.setCategory(index, category)
                                onDeleteRequested: win.setCategory(index, null)
                            }
                        }
                    }

                    FlowColumn {
                        Layout.preferredWidth: (win.width - Theme.spacingL * 2 - Theme.spacingM) * 0.34
                        Layout.fillHeight: true
                        items: win.flowItems
                        emptyReason: win.searchQuery ? "no matches for this search" : "no notifications yet"
                    }
                }

                // --------------------------------------------------- search bar
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48

                    SearchBar {
                        id: searchField

                        anchors.horizontalCenter: parent.horizontalCenter
                        text: win.searchQuery
                        onTextEdited: win.searchQuery = text
                    }
                }
            }
        }
    }
}
