import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import "commands.js" as Commands

// The fullscreen surface. Must come from a LazyLoader, never be declared
// inline inside the PluginComponent — an inline PanelWindow never becomes a
// layer surface. The daemon keeps the loader permanently active and this
// window's own `open` property maps/unmaps it, so it isn't rebuilt (and the
// Tailscale subscription isn't re-established) on every open.
PanelWindow {
    id: win

    readonly property string pluginId: "controlPanel"

    property bool open: false
    signal closeRequested

    readonly property bool keyboardReady: rootFocus.activeFocus
    readonly property bool searchFocused: searchBar.hasFocus

    // -------------------------------------------------------------- search
    property string searchQuery: ""
    readonly property var parsedCommand: Commands.parseCommand(searchQuery)

    function queryFor(section) {
        if (parsedCommand.command === section)
            return parsedCommand.query;
        if (parsedCommand.command === null)
            return searchQuery;
        return "";
    }

    function topKeyFor(section, list) {
        return parsedCommand.command === section && list.length > 0 ? list[0].key : "";
    }

    function clearSearch() {
        win.searchQuery = "";
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
        win.searchQuery = next;
        searchBar.text = next;
        searchBar.field.cursorPosition = i;
    }

    // ------------------------------------------------------------ wifi data
    readonly property var wifiFiltered: {
        const q = queryFor("wifi");
        return (NetworkService.wifiNetworks || []).filter(n => Commands.matches(n.ssid, q)).map(n => ({
                    key: n.ssid,
                    label: n.ssid || "Unknown",
                    meta: (n.ssid === NetworkService.currentWifiSSID ? "Connected" : (n.secured ? "Secured" : "Open")) + " · " + (n.signal || 0) + "%",
                    connected: n.ssid === NetworkService.currentWifiSSID,
                    busy: NetworkService.isWifiConnecting && NetworkService.connectingSSID === n.ssid,
                    icon: "wifi",
                    ssid: n.ssid
                }));
    }

    function connectWifi(item) {
        if (item)
            NetworkService.connectToWifi(item.ssid);
    }

    // ------------------------------------------------------- bluetooth data
    readonly property var bluetoothFiltered: {
        const q = queryFor("bluetooth");
        const devices = BluetoothService.pairedDevices || [];
        return devices.filter(d => Commands.matches(d.name || d.deviceName, q)).map(d => ({
                    key: (d.address || d.name || d.deviceName || ""),
                    label: d.name || d.deviceName || "Unknown device",
                    meta: d.connected ? "Connected" : (d.paired ? "Paired" : ""),
                    connected: d.connected === true,
                    busy: BluetoothService.isDeviceBusy(d),
                    icon: BluetoothService.getDeviceIcon(d) || "bluetooth",
                    device: d
                }));
    }

    function connectBluetooth(item) {
        if (item)
            BluetoothService.connectDeviceWithTrust(item.device);
    }

    // --------------------------------------------------------- speaker data
    readonly property var speakerFiltered: {
        const q = queryFor("speaker");
        const nodes = AudioService.typedSinks || [];
        return nodes.filter(n => Commands.matches(AudioService.displayName(n), q)).map(n => ({
                    key: n.name,
                    label: AudioService.displayName(n),
                    meta: n === AudioService.sink ? "Active" : "Available",
                    connected: n === AudioService.sink,
                    busy: false,
                    icon: AudioService.sinkIcon(n) || "speaker",
                    node: n
                }));
    }

    function selectSpeaker(item) {
        if (item)
            AudioService.setDefaultSinkByName(item.key);
    }

    // ------------------------------------------------------------- vpn data
    readonly property var vpnRows: {
        const active = NetworkService.vpnActive || [];
        return (NetworkService.vpnProfiles || []).map(p => ({
                    uuid: p.uuid,
                    name: p.name,
                    connected: active.some(a => a.uuid === p.uuid)
                }));
    }

    function toggleVpn(uuid) {
        NetworkService.activeService?.toggle(uuid);
    }

    // ------------------------------------------------------------- toggles
    function toggleMic() {
        if (AudioService.source && AudioService.source.audio)
            AudioService.source.audio.muted = !AudioService.source.audio.muted;
    }

    function toggleTailscale() {
        if (TailscaleService.connected)
            TailscaleService.disconnectTailscale();
        else
            TailscaleService.connectTailscale();
    }

    function toggleKeepAwake() {
        SessionService.toggleIdleInhibit();
    }

    // ------------------------------------------------------- enter-to-connect
    function handleSearchAccepted() {
        const cmd = parsedCommand.command;
        if (cmd === "wifi" && wifiFiltered.length > 0)
            connectWifi(wifiFiltered[0]);
        else if (cmd === "bluetooth" && bluetoothFiltered.length > 0)
            connectBluetooth(bluetoothFiltered[0]);
        else if (cmd === "speaker" && speakerFiltered.length > 0)
            selectSpeaker(speakerFiltered[0]);
        focusAnchor.forceActiveFocus();
    }

    Component.onCompleted: TailscaleService.refCount++
    Component.onDestruction: TailscaleService.refCount--

    visible: open
    color: "transparent"

    WlrLayershell.namespace: "dms:control-panel"
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
            // silently reclaim focus at moments it shouldn't.
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
                if (win.searchFocused)
                    return;

                if (event.key === Qt.Key_Slash) {
                    searchBar.field.forceActiveFocus();
                    event.accepted = true;
                    return;
                }

                switch (event.key) {
                case Qt.Key_W:
                    NetworkService.toggleWifiRadio();
                    event.accepted = true;
                    break;
                case Qt.Key_B:
                    BluetoothService.setBluetoothEnabled(!BluetoothService.enabled);
                    event.accepted = true;
                    break;
                case Qt.Key_S:
                    if (AudioService.sink && AudioService.sink.audio)
                        AudioService.sink.audio.muted = !AudioService.sink.audio.muted;
                    event.accepted = true;
                    break;
                case Qt.Key_M:
                    win.toggleMic();
                    event.accepted = true;
                    break;
                case Qt.Key_T:
                    win.toggleTailscale();
                    event.accepted = true;
                    break;
                case Qt.Key_K:
                    win.toggleKeepAwake();
                    event.accepted = true;
                    break;
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

                        name: "tune"
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
                            text: "Control Panel"
                            font.pixelSize: Theme.fontSizeLarge + 2
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: "W/B/S/M/T/K toggles · / to search"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
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

                // -------------------------------------------------- 2x2 grid
                GridLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    columns: 2
                    rows: 2
                    columnSpacing: Theme.spacingM
                    rowSpacing: Theme.spacingM

                    ListContainer {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        letter: "W"
                        title: "WiFi"
                        iconName: "wifi"
                        statusText: NetworkService.wifiEnabled ? (NetworkService.currentWifiSSID || "Not connected") : "Off"
                        toggleOn: NetworkService.wifiEnabled
                        items: win.wifiFiltered
                        topKey: win.topKeyFor("wifi", win.wifiFiltered)
                        emptyText: NetworkService.wifiEnabled ? "No networks found" : "WiFi is off"
                        onToggleRequested: NetworkService.toggleWifiRadio()
                        onActivated: item => win.connectWifi(item)
                    }

                    ListContainer {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        letter: "B"
                        title: "Bluetooth"
                        iconName: "bluetooth"
                        statusText: BluetoothService.enabled ? (BluetoothService.connected ? "Connected" : "On") : "Off"
                        toggleOn: BluetoothService.enabled
                        items: win.bluetoothFiltered
                        topKey: win.topKeyFor("bluetooth", win.bluetoothFiltered)
                        emptyText: BluetoothService.enabled ? "No paired devices" : "Bluetooth is off"
                        onToggleRequested: BluetoothService.setBluetoothEnabled(!BluetoothService.enabled)
                        onActivated: item => win.connectBluetooth(item)
                    }

                    ListContainer {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        letter: "S"
                        title: "Speaker"
                        iconName: "volume_up"
                        statusText: AudioService.sink && AudioService.sink.audio && AudioService.sink.audio.muted ? "Muted" : (AudioService.sink ? AudioService.displayName(AudioService.sink) : "")
                        toggleOn: !(AudioService.sink && AudioService.sink.audio && AudioService.sink.audio.muted)
                        items: win.speakerFiltered
                        topKey: win.topKeyFor("speaker", win.speakerFiltered)
                        emptyText: "No output devices"
                        onToggleRequested: {
                            if (AudioService.sink && AudioService.sink.audio)
                                AudioService.sink.audio.muted = !AudioService.sink.audio.muted;
                        }
                        onActivated: item => win.selectSpeaker(item)
                    }

                    // ------------------------------------------------- other
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: Theme.cornerRadius
                        color: Theme.floatingWindowNestedSurface
                        border.color: Theme.outlineMedium
                        border.width: Theme.layerOutlineWidth
                        clip: true

                        Column {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Item {
                                width: parent.width
                                height: 26

                                DankIcon {
                                    id: otherIcon

                                    name: "more_horiz"
                                    size: 18
                                    color: Theme.primary
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    anchors.left: otherIcon.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Other"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.outlineVariant
                                opacity: 0.5
                            }

                            Item {
                                width: parent.width
                                height: parent.height - 26 - 1 - Theme.spacingS * 2

                                DankFlickable {
                                    anchors.fill: parent
                                    clip: true
                                    contentHeight: otherCol.height
                                    contentWidth: width

                                    Column {
                                        id: otherCol

                                        width: parent.width
                                        spacing: 1

                                        ToggleRow {
                                            iconName: "mic"
                                            label: "Microphone"
                                            letter: "M"
                                            checked: !(AudioService.source && AudioService.source.audio && AudioService.source.audio.muted)
                                            onToggled: win.toggleMic()
                                        }

                                        ToggleRow {
                                            iconName: "vpn_lock"
                                            label: "Tailscale"
                                            letter: "T"
                                            meta: TailscaleService.available ? "" : "not installed"
                                            checked: TailscaleService.connected
                                            enabled: TailscaleService.available
                                            onToggled: win.toggleTailscale()
                                        }

                                        ToggleRow {
                                            iconName: "coffee"
                                            label: "Keep Awake"
                                            letter: "K"
                                            meta: "Prevent screen lock/sleep"
                                            checked: SessionService.idleInhibited
                                            onToggled: win.toggleKeepAwake()
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: "VPN"
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                            topPadding: Theme.spacingS
                                            visible: win.vpnRows.length > 0
                                        }

                                        Repeater {
                                            model: win.vpnRows

                                            ToggleRow {
                                                required property var modelData

                                                iconName: "shield"
                                                label: modelData.name
                                                checked: modelData.connected
                                                onToggled: win.toggleVpn(modelData.uuid)
                                            }
                                        }

                                        StyledText {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            text: "No VPN profiles configured"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            visible: win.vpnRows.length === 0
                                            topPadding: Theme.spacingS
                                        }
                                    }
                                }
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
