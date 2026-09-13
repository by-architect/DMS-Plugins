pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Owns the configuration, the per-screen line stacks, and the switch that
// takes the shipped notification popups off screen.
//
// The plugin is deliberately *not* its own notification server: DMS's
// NotificationService already does the D-Bus work, dedupe, rules, DND and the
// per-urgency expiry timers. This daemon only renders a different view of
// NotificationService.visibleNotifications, so everything a user configures
// under Settings -> Notifications (timeouts, rules, DND, history) keeps
// working exactly as before.
PluginComponent {
    id: root

    // Written into SettingsData.screenPreferences.notifications to make the
    // shell's own popup manager match zero screens. It is a screen name that
    // can never exist, which is the only way DMS lets you say "nowhere" --
    // an empty list means "everywhere".
    readonly property string suppressSentinel: "notificationLine-suppressed"

    function cfgValue(key, fallback) {
        const data = root.pluginData;
        if (!data)
            return fallback;
        const v = data[key];
        return (v === undefined || v === null) ? fallback : v;
    }

    readonly property string position: cfgValue("position", "bottom-right")
    readonly property string monitors: cfgValue("monitors", "all")
    readonly property int maxLines: Math.max(1, Math.min(12, cfgValue("maxLines", 6)))
    readonly property int widthPercent: Math.max(15, Math.min(100, cfgValue("widthPercent", 50)))
    readonly property int fontSize: Math.max(8, Math.min(28, cfgValue("fontSize", 13)))
    readonly property int backgroundOpacity: Math.max(0, Math.min(100, cfgValue("backgroundOpacity", 72)))
    readonly property int lineSpacing: Math.max(0, Math.min(16, cfgValue("lineSpacing", 3)))
    readonly property int marginH: Math.max(0, Math.min(200, cfgValue("marginH", 12)))
    readonly property int marginV: Math.max(0, Math.min(200, cfgValue("marginV", 12)))
    readonly property int expandedMaxLines: Math.max(2, Math.min(20, cfgValue("expandedMaxLines", 8)))
    readonly property bool showTime: cfgValue("showTime", true)
    readonly property bool showIcon: cfgValue("showIcon", true)
    readonly property bool showAppName: cfgValue("showAppName", true)
    readonly property bool suppressBuiltin: cfgValue("suppressBuiltin", true)

    // "focused" mode is resolved when a notification arrives rather than
    // continuously: the compositor's focused output is a poll, not a binding,
    // and a line that hops monitors mid-life would be worse than one that
    // stays where it was raised.
    property string focusedScreenName: ""

    function refreshFocusedScreen() {
        if (root.monitors !== "focused") {
            root.focusedScreenName = "";
            return;
        }
        const s = CompositorService.getFocusedScreen();
        root.focusedScreenName = s ? s.name : "";
    }

    Connections {
        target: NotificationService

        function onVisibleNotificationsChanged() {
            root.refreshFocusedScreen();
        }
    }

    onMonitorsChanged: refreshFocusedScreen()

    // ---- built-in popup suppression -------------------------------------

    property bool _suppressionApplied: false

    function _screenPrefs() {
        return SettingsData.screenPreferences || ({});
    }

    function _setNotificationScreens(value) {
        const next = Object.assign({}, root._screenPrefs());
        next["notifications"] = value;
        SettingsData.set("screenPreferences", next);
    }

    function applySuppression() {
        if (root._suppressionApplied)
            return;
        const current = root._screenPrefs()["notifications"] || ["all"];
        // Never record the sentinel as the "previous" value -- that would make
        // the restore a no-op after a shell reload.
        if (current.length !== 1 || current[0] !== root.suppressSentinel) {
            PluginService.savePluginData(root.pluginId, "_savedScreens", current);
            PluginService.savePluginData(root.pluginId, "_savedFocusedMonitor", SettingsData.notificationFocusedMonitor === true);
        }
        // notificationFocusedMonitor short-circuits the screen filter entirely,
        // so it has to come down with it.
        if (SettingsData.notificationFocusedMonitor)
            SettingsData.set("notificationFocusedMonitor", false);
        root._setNotificationScreens([root.suppressSentinel]);
        root._suppressionApplied = true;
        console.info("notificationLine: shipped notification popups suppressed");
    }

    function releaseSuppression() {
        const current = root._screenPrefs()["notifications"] || [];
        const isSuppressed = current.length === 1 && current[0] === root.suppressSentinel;
        if (!isSuppressed) {
            root._suppressionApplied = false;
            return;
        }
        const saved = PluginService.loadPluginData(root.pluginId, "_savedScreens", ["all"]);
        root._setNotificationScreens((saved && saved.length) ? saved : ["all"]);
        const savedFocused = PluginService.loadPluginData(root.pluginId, "_savedFocusedMonitor", false);
        if (savedFocused === true)
            SettingsData.set("notificationFocusedMonitor", true);
        root._suppressionApplied = false;
        console.info("notificationLine: shipped notification popups restored");
    }

    function syncSuppression() {
        if (root.suppressBuiltin)
            root.applySuppression();
        else
            root.releaseSuppression();
    }

    onSuppressBuiltinChanged: syncSuppression()

    // ---- queue depth -----------------------------------------------------

    // NotificationService only lets four popups coexist; past that it queues.
    // A line stack is cheap enough to show more, so the service is told how
    // many this plugin is prepared to draw.
    property int _savedMaxVisible: -1

    function applyQueueDepth() {
        if (root._savedMaxVisible < 0)
            root._savedMaxVisible = NotificationService.maxVisibleNotifications;
        NotificationService.maxVisibleNotifications = root.maxLines;
    }

    function restoreQueueDepth() {
        if (root._savedMaxVisible >= 0)
            NotificationService.maxVisibleNotifications = root._savedMaxVisible;
        root._savedMaxVisible = -1;
    }

    onMaxLinesChanged: applyQueueDepth()

    Component.onCompleted: {
        applyQueueDepth();
        syncSuppression();
        console.info("notificationLine: daemon ready (ipc target 'notificationLine')");
    }

    Component.onDestruction: {
        restoreQueueDepth();
        releaseSuppression();
    }

    // One stack per screen. Variants instantiates the delegate dynamically,
    // which is what lets its PanelWindow become a real layer surface -- a
    // PanelWindow declared inline in this component never would.
    Variants {
        model: Quickshell.screens

        delegate: NotificationLineWindow {
            host: root
        }
    }

    IpcHandler {
        target: "notificationLine"

        function test(): string {
            NotificationService.sendTestNotification(0);
            return "SENT";
        }

        function clear(): string {
            NotificationService.dismissAllPopups();
            return "CLEARED";
        }

        function suppress(state: string): string {
            const on = state !== "off" && state !== "false" && state !== "0";
            PluginService.savePluginData(root.pluginId, "suppressBuiltin", on);
            return on ? "SUPPRESSED" : "RESTORED";
        }

        function status(): string {
            return [root.position, "lines=" + NotificationService.visibleNotifications.length + "/" + root.maxLines, "suppressed=" + root._suppressionApplied].join("\t");
        }
    }
}
