import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import "wallhaven.js" as Wallhaven

// The fullscreen surface. Must come from a LazyLoader, never be declared
// inline inside the PluginComponent — an inline PanelWindow never becomes a
// layer surface. The daemon keeps the loader permanently active and this
// window's own `open` property maps/unmaps it, so search results and the
// local folder scan persist across opens instead of being rebuilt every time.
PanelWindow {
    id: win

    readonly property string pluginId: "wallpaperSearch"

    property bool open: false
    signal closeRequested

    readonly property bool keyboardReady: rootFocus.activeFocus
    readonly property bool searchFocused: searchBar.hasFocus

    // ------------------------------------------------------------ settings
    property string localPath: "~/Pictures/Wallpapers"
    property string installLocation: "~/Pictures/Wallpapers/wallhaven"

    function loadSettings() {
        localPath = PluginService.loadPluginData(pluginId, "localPath", "~/Pictures/Wallpapers");
        installLocation = PluginService.loadPluginData(pluginId, "installLocation", "~/Pictures/Wallpapers/wallhaven");
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(changedId) {
            if (changedId === win.pluginId)
                win.loadSettings();
        }
    }

    // --------------------------------------------------------------- tabs
    readonly property int tabCount: 2
    property int activeTab: 0

    function setTab(index) {
        activeTab = ((index % tabCount) + tabCount) % tabCount;
        if (activeTab === 1 && !localScanned)
            scanLocal();
    }

    function nextTab() {
        setTab(activeTab + 1);
    }

    function prevTab() {
        setTab(activeTab - 1);
    }

    // ------------------------------------------------------------- search
    property string searchQuery: ""

    function clearSearch() {
        searchQuery = "";
        searchBar.text = "";
    }

    function deleteSearchWord() {
        const text = searchBar.text;
        const pos = searchBar.field.cursorPosition;
        if (pos === 0)
            return;
        let i = pos;
        while (i > 0 && /\s/.test(text[i - 1]))
            i--;
        while (i > 0 && !/\s/.test(text[i - 1]))
            i--;
        const next = text.slice(0, i) + text.slice(pos);
        searchQuery = next;
        searchBar.text = next;
        searchBar.field.cursorPosition = i;
    }

    // Enter behaves differently per tab: Wallhaven fires the API search;
    // Local's filter is already live, so Enter there just hands focus back
    // to the grid. Either way, focus returns to panel mode so Ctrl+hjkl
    // navigation works immediately without an extra unfocus step.
    function handleSearchAccepted() {
        if (activeTab === 0)
            searchWallhaven(searchQuery);
        focusAnchor.forceActiveFocus();
    }

    // -------------------------------------------------------- wallhaven tab
    property var wallhavenItems: []
    property int wallhavenIndex: -1
    property string wallhavenActiveQuery: ""
    property int wallhavenPage: 1
    property int wallhavenLastPage: 1
    // Wallhaven ignores a bigger per_page (always 24/page), so "more on the
    // first search" means fetching this many pages up front instead of one.
    readonly property int wallhavenPrefetchPages: 2
    property bool wallhavenLoading: false
    property bool wallhavenLoadingMore: false
    property string wallhavenError: ""
    property bool wallhavenApplying: false

    // page 1 replaces the results; every later page appends. A fresh search,
    // the auto-prefetch chain below it, and Space-to-load-more all funnel
    // through this one function. `autoChain` marks a call as part of the
    // initial fill-the-screen sequence (as opposed to a user-triggered
    // load-more) — only those keep fetching until wallhavenPrefetchPages;
    // a manual Space press always fetches exactly one more page.
    function fetchWallhavenPage(page, append, autoChain) {
        if (append)
            wallhavenLoadingMore = true;
        else
            wallhavenLoading = true;
        wallhavenError = "";
        wallhavenPage = page;
        const url = Wallhaven.searchUrl(wallhavenActiveQuery, page);
        Proc.runCommand("wallpaperSearch:wallhaven", ["curl", "-s", url], (output, exitCode) => {
            wallhavenLoading = false;
            wallhavenLoadingMore = false;
            if (exitCode !== 0) {
                if (append)
                    ToastService.showError("Load more failed (network error)");
                else
                    wallhavenError = "Search failed (network error)";
                return;
            }
            const parsed = Wallhaven.parseResults(output);
            if (!parsed) {
                if (append)
                    ToastService.showError("Load more failed (bad response — rate limited?)");
                else
                    wallhavenError = "Search failed (bad response — rate limited?)";
                return;
            }

            wallhavenLastPage = parsed.lastPage;
            if (append) {
                wallhavenItems = wallhavenItems.concat(parsed.items);
            } else {
                wallhavenItems = parsed.items;
                selectWallhaven(parsed.items.length > 0 ? 0 : -1);
                if (parsed.items.length === 0)
                    wallhavenError = "No results";
            }

            // Keep fetching while still inside the initial fill-the-screen
            // window — a 24-result first page rarely covers a fullscreen
            // grid on its own. A manual load-more (autoChain unset) never
            // continues past the one page it asked for.
            if (autoChain && page < wallhavenPrefetchPages && page < wallhavenLastPage)
                fetchWallhavenPage(page + 1, true, true);
        });
    }

    function searchWallhaven(query) {
        wallhavenActiveQuery = query;
        wallhavenItems = [];
        fetchWallhavenPage(1, false, true);
    }

    function loadMoreWallhaven() {
        if (activeTab !== 0 || wallhavenLoading || wallhavenLoadingMore)
            return;
        if (wallhavenItems.length === 0 || wallhavenPage >= wallhavenLastPage)
            return;
        fetchWallhavenPage(wallhavenPage + 1, true, false);
    }

    function applyWallhavenSelection() {
        if (activeTab !== 0 || wallhavenApplying)
            return;
        const item = wallhavenItems[wallhavenIndex];
        if (!item || !item.full)
            return;

        wallhavenApplying = true;
        const dir = Paths.expandTilde(win.installLocation);
        const ext = Wallhaven.extensionFor(item.full);
        const dest = dir + "/" + item.key + "." + ext;

        // mkdir and the download run as one shell command (not
        // Paths.mkdir()'s fire-and-forget execDetached) so the directory is
        // guaranteed to exist before curl tries to write into it.
        Proc.runCommand("wallpaperSearch:download", ["sh", "-c", `mkdir -p '${dir}' && curl -sL '${item.full}' --output '${dest}'`], (output, exitCode) => {
            wallhavenApplying = false;
            if (exitCode !== 0) {
                ToastService.showError("Wallpaper download failed");
                return;
            }
            SessionData.setWallpaper(dest);
            ToastService.showInfo("Wallpaper applied", item.key);
        });
    }

    // ------------------------------------------------------------ local tab
    property var localAll: []
    property bool localScanned: false
    property bool localLoading: false
    property string localError: ""
    property int localIndex: -1

    readonly property var localFiltered: {
        const q = searchQuery.trim().toLowerCase();
        if (!q)
            return localAll;
        return localAll.filter(it => it.name.toLowerCase().includes(q));
    }

    onLocalFilteredChanged: selectLocal(localFiltered.length > 0 ? 0 : -1)

    function scanLocal() {
        localScanned = true;
        localLoading = true;
        localError = "";
        const dir = Paths.expandTilde(win.localPath);
        const cmd = ["find", dir, "-maxdepth", "4", "-type", "f", "(", "-iname", "*.jpg", "-o", "-iname", "*.jpeg", "-o", "-iname", "*.png", "-o", "-iname", "*.webp", "-o", "-iname", "*.avif", ")"];
        Proc.runCommand("wallpaperSearch:local", cmd, (output, exitCode) => {
            localLoading = false;
            const lines = (output || "").split("\n").map(l => l.trim()).filter(l => l.length > 0);
            if (lines.length === 0) {
                localError = exitCode !== 0 ? "Folder not found: " + win.localPath : "No images found in " + win.localPath;
                localAll = [];
                return;
            }
            localAll = lines.map(path => ({
                        key: path,
                        name: path.split("/").pop(),
                        thumb: "file://" + path,
                        full: path
                    }));
        });
    }

    function applyLocalSelection() {
        if (activeTab !== 1)
            return;
        const item = localFiltered[localIndex];
        if (!item)
            return;
        SessionData.setWallpaper(item.full);
        ToastService.showInfo("Wallpaper applied", item.name);
    }

    // --------------------------------------------------------- grid nav
    function currentItems() {
        return activeTab === 0 ? wallhavenItems : localFiltered;
    }

    function currentGrid() {
        return activeTab === 0 ? wallhavenGrid : localGrid;
    }

    // The one path every selection change goes through, imperative on both
    // sides (index property + grid.currentIndex) rather than half-declarative:
    // a GridView's `currentIndex` binding is silently dropped the first time
    // anything assigns to it directly (standard QML binding-override
    // behavior), so mixing `currentIndex: win.xIndex` with imperative
    // assignments elsewhere would desync the visual highlight from the real
    // selection after the first click or keypress.
    function selectWallhaven(index) {
        wallhavenIndex = index;
        wallhavenGrid.currentIndex = index;
        if (index >= 0)
            wallhavenGrid.positionViewAtIndex(index, GridView.Contain);
    }

    function selectLocal(index) {
        localIndex = index;
        localGrid.currentIndex = index;
        if (index >= 0)
            localGrid.positionViewAtIndex(index, GridView.Contain);
    }

    function moveSelection(dx, dy) {
        const items = currentItems();
        if (items.length === 0)
            return;
        const grid = currentGrid();
        const columns = Math.max(1, Math.floor(grid.width / grid.cellWidth));
        let index = activeTab === 0 ? wallhavenIndex : localIndex;
        if (index < 0)
            index = 0;

        if (dx !== 0) {
            index = Math.max(0, Math.min(items.length - 1, index + dx));
        } else if (dy !== 0) {
            const next = index + dy * columns;
            if (next >= 0 && next < items.length)
                index = next;
        }

        if (activeTab === 0)
            selectWallhaven(index);
        else
            selectLocal(index);
    }

    onOpenChanged: {
        if (open) {
            loadSettings();
            searchBar.field.forceActiveFocus();
        }
    }

    Component.onCompleted: loadSettings()

    visible: open
    color: "transparent"

    WlrLayershell.namespace: "dms:wallpaper-search"
    WlrLayershell.layer: WlrLayer.Overlay

    // Mirrors the shell's own focus policy: Hyprland's default configuration
    // ignores layer-shell exclusive keyboard focus and uses
    // hyprland_focus_grab instead.
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

            // A FocusScope's forceActiveFocus() backfills to whichever
            // descendant last held focus rather than focusing the scope
            // itself, and the window persists across close/reopen instead of
            // being destroyed — so without this, the search field could
            // silently reclaim focus at moments it shouldn't. This concrete
            // leaf item is the reset target whenever we want panel-level
            // (not search-field) focus.
            Item {
                id: focusAnchor

                width: 0
                height: 0
                focus: true
            }

            Keys.onEscapePressed: {
                if (win.searchFocused)
                    focusAnchor.forceActiveFocus();
                else
                    win.closeRequested();
            }

            Keys.onPressed: event => {
                const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
                const alt = (event.modifiers & Qt.AltModifier) !== 0;

                if (win.searchFocused && ctrl && event.key === Qt.Key_U) {
                    win.clearSearch();
                    event.accepted = true;
                    return;
                }
                if (win.searchFocused && ctrl && event.key === Qt.Key_W) {
                    win.deleteSearchWord();
                    event.accepted = true;
                    return;
                }

                // Modifier combos below are unambiguous (Ctrl/Alt+Enter never
                // types a character), so they're live regardless of whether
                // the search field currently has focus.
                if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                    win.applyWallhavenSelection();
                    event.accepted = true;
                    return;
                }
                if (alt && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                    win.applyLocalSelection();
                    event.accepted = true;
                    return;
                }
                if (alt && event.key === Qt.Key_J) {
                    win.nextTab();
                    event.accepted = true;
                    return;
                }
                if (alt && event.key === Qt.Key_K) {
                    win.prevTab();
                    event.accepted = true;
                    return;
                }

                if (win.searchFocused)
                    return;

                if (event.key === Qt.Key_Slash) {
                    searchBar.field.forceActiveFocus();
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Space) {
                    win.loadMoreWallhaven();
                    event.accepted = true;
                    return;
                }
                if (ctrl) {
                    switch (event.key) {
                    case Qt.Key_H:
                        win.moveSelection(-1, 0);
                        event.accepted = true;
                        break;
                    case Qt.Key_L:
                        win.moveSelection(1, 0);
                        event.accepted = true;
                        break;
                    case Qt.Key_J:
                        win.moveSelection(0, 1);
                        event.accepted = true;
                        break;
                    case Qt.Key_K:
                        win.moveSelection(0, -1);
                        event.accepted = true;
                        break;
                    }
                }
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

                        name: "wallpaper"
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
                            text: "Wallpaper Search"
                            font.pixelSize: Theme.fontSizeLarge + 2
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: "/ search · Space more · Ctrl+hjkl select · Ctrl+Enter apply (Wallhaven) · Alt+Enter apply (Local) · Alt+j/k tabs"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    DankTabBar {
                        anchors.centerIn: parent
                        width: 280
                        model: [{
                                text: "Wallhaven",
                                icon: "public"
                            }, {
                                text: "Local",
                                icon: "folder"
                            }]
                        currentIndex: win.activeTab
                        tabHeight: 36
                        onTabClicked: index => win.setTab(index)
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingM

                        StyledText {
                            text: "Esc unfocus search · Esc again closes"
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

                // ------------------------------------------------------ grids
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    DankGridView {
                        id: wallhavenGrid

                        anchors.fill: parent
                        visible: win.activeTab === 0
                        clip: true
                        cellWidth: Math.max(170, width / Math.floor(width / 200))
                        cellHeight: cellWidth * 0.62
                        model: win.wallhavenItems
                        keyNavigationEnabled: false
                        interactive: true

                        delegate: Item {
                            required property var modelData
                            required property int index

                            width: wallhavenGrid.cellWidth
                            height: wallhavenGrid.cellHeight

                            ThumbnailCell {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingXS
                                item: modelData
                                isCurrent: index === win.wallhavenIndex
                                isBusy: win.wallhavenApplying && index === win.wallhavenIndex
                                onActivated: win.selectWallhaven(index)
                            }
                        }
                    }

                    DankGridView {
                        id: localGrid

                        anchors.fill: parent
                        visible: win.activeTab === 1
                        clip: true
                        cellWidth: Math.max(170, width / Math.floor(width / 200))
                        cellHeight: cellWidth * 0.62
                        model: win.localFiltered
                        keyNavigationEnabled: false
                        interactive: true

                        delegate: Item {
                            required property var modelData
                            required property int index

                            width: localGrid.cellWidth
                            height: localGrid.cellHeight

                            ThumbnailCell {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingXS
                                item: modelData
                                isCurrent: index === win.localIndex
                                onActivated: win.selectLocal(index)
                            }
                        }
                    }

                    // ---------------------------------------------- empty/status states
                    // Gated on there being zero items, not just "loading" —
                    // otherwise the background page-2+ prefetch or a Space
                    // load-more would cover the results that are already on
                    // screen with a spinner instead of appending quietly
                    // beneath them.
                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS
                        width: parent.width - Theme.spacingXL * 2
                        visible: win.activeTab === 0 ? win.wallhavenItems.length === 0 : (win.localLoading || win.localError.length > 0)

                        DankSpinner {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: win.activeTab === 0 ? win.wallhavenLoading : win.localLoading
                            running: visible
                            size: 28
                        }

                        DankIcon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: !(win.activeTab === 0 ? win.wallhavenLoading : win.localLoading)
                            name: win.activeTab === 0 ? "wallpaper" : "folder_open"
                            size: 26
                            color: Theme.surfaceVariantText
                            opacity: 0.6
                        }

                        StyledText {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            text: {
                                if (win.activeTab === 0) {
                                    if (win.wallhavenLoading)
                                        return "Searching Wallhaven…";
                                    if (win.wallhavenError)
                                        return win.wallhavenError;
                                    return "Type a query and press Enter to search Wallhaven";
                                }
                                if (win.localLoading)
                                    return "Scanning " + win.localPath + "…";
                                if (win.localError)
                                    return win.localError + "\n(configure the folder in plugin settings)";
                                return "";
                            }
                        }
                    }

                    // ---------------------------------------- load-more indicator
                    Row {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottomMargin: Theme.spacingM
                        spacing: Theme.spacingS
                        visible: win.activeTab === 0 && win.wallhavenItems.length > 0

                        DankSpinner {
                            visible: win.wallhavenLoadingMore
                            running: visible
                            size: 16
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            text: {
                                if (win.wallhavenLoadingMore)
                                    return "Loading more…";
                                if (win.wallhavenPage >= win.wallhavenLastPage)
                                    return win.wallhavenItems.length + " results — end reached";
                                return win.wallhavenItems.length + " results — Space for more";
                            }
                        }
                    }
                }

                // --------------------------------------------------- search bar
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48

                    SearchBar {
                        id: searchBar

                        anchors.horizontalCenter: parent.horizontalCenter
                        text: win.searchQuery
                        onTextEdited: win.searchQuery = text
                        onAccepted: win.handleSearchAccepted()
                    }
                }
            }
        }
    }
}
