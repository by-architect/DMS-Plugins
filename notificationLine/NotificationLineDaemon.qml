pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Owns the configuration, the expiry clock, the per-screen line stacks, and
// the switch that takes the shipped notification popups off screen.
//
// The plugin is deliberately *not* its own notification server: DMS's
// NotificationService already does the D-Bus work, dedupe, rules and DND.
// This daemon renders a different view of its
// NotificationService.visibleNotifications, so everything a user configures
// under Settings -> Notifications keeps working.
//
// Expiry is the one thing the plugin takes over, because the shell's own
// per-notification timer honours whatever `expire_timeout` the sending app
// asked for -- which is why notifications from different apps vanish at
// wildly different speeds while the ones that pass -1 obey the configured
// timeout. See `ownsTiming` below.
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
    readonly property int lifetime: Math.max(0, Math.min(300, cfgValue("lifetime", 0)))
    readonly property bool ignoreAppTimeout: cfgValue("ignoreAppTimeout", true)
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

    onMonitorsChanged: refreshFocusedScreen()

    // ---- the lines currently on screen -----------------------------------

    function visibleList() {
        return NotificationService.visibleNotifications.filter(w => w && w.popup);
    }

    // Leaves the stack, stays in the notification centre -- the same thing
    // swiping a shipped popup away does.
    function retire(w) {
        if (!w)
            return false;
        w.popup = false;
        return true;
    }

    // ---- expiry ----------------------------------------------------------
    //
    // Timing lives here rather than in the line, because the line delegates
    // are rebuilt whenever the stack changes and a per-delegate timer would
    // restart everyone's countdown every time a new notification arrived.

    readonly property bool ownsTiming: root.lifetime > 0 || root.ignoreAppTimeout

    // [{ w, at, holds }] -- `at` is when the line last started counting down,
    // `holds` how many lines (one per screen) are hovering or unfolded it.
    property var tracked: []

    function entryFor(w) {
        for (const e of root.tracked) {
            if (e.w === w)
                return e;
        }
        return null;
    }

    function timeoutFor(w) {
        if (root.lifetime > 0)
            return root.lifetime * 1000;
        if (!w)
            return 0;
        switch (w.urgency) {
        case NotificationUrgency.Low:
            return SettingsData.notificationTimeoutLow;
        case NotificationUrgency.Critical:
            return SettingsData.notificationTimeoutCritical;
        default:
            return SettingsData.notificationTimeoutNormal;
        }
    }

    function syncTracked() {
        const vis = root.visibleList();
        const next = [];
        for (const w of vis) {
            let e = root.entryFor(w);
            if (!e) {
                e = {
                    "w": w,
                    "at": Date.now(),
                    "holds": 0
                };
                if (root.ownsTiming && w.timer)
                    w.timer.stop();
            }
            next.push(e);
        }
        root.tracked = next;
    }

    // Called by every line that starts or stops hovering/unfolding. Holds are
    // counted, not set, because with "All monitors" one notification has one
    // line per screen.
    function hold(w, on) {
        if (!w)
            return;
        const e = root.entryFor(w);
        if (on) {
            if (e)
                e.holds++;
            if (!root.ownsTiming && w.timer)
                w.timer.stop();
            return;
        }
        if (e) {
            e.holds = Math.max(0, e.holds - 1);
            if (e.holds > 0)
                return;
            // A released line gets its full time back, the same way the
            // shipped popup restarts its timer on mouse-out.
            e.at = Date.now();
        }
        if (!root.ownsTiming && w.timer)
            w.timer.restart();
    }

    function reap() {
        const now = Date.now();
        for (const e of root.tracked) {
            if (!e.w || e.holds > 0)
                continue;
            const ms = root.timeoutFor(e.w);
            // 0 means "never expires" -- critical notifications default to it.
            if (ms > 0 && now - e.at >= ms)
                root.retire(e.w);
        }
    }

    Timer {
        interval: 250
        repeat: true
        running: root.ownsTiming && root.tracked.length > 0
        onTriggered: root.reap()
    }

    // Handing timing back and forth has to leave the shell's own timers in a
    // sane state, or a notification stranded with a stopped timer never goes
    // away again.
    onOwnsTimingChanged: {
        for (const e of root.tracked) {
            if (!e.w || !e.w.timer)
                continue;
            if (root.ownsTiming) {
                e.w.timer.stop();
                e.at = Date.now();
            } else if (e.holds === 0) {
                e.w.timer.restart();
            }
        }
    }

    function releaseTiming() {
        if (!root.ownsTiming)
            return;
        for (const e of root.tracked) {
            if (e.w && e.w.timer)
                e.w.timer.restart();
        }
        root.tracked = [];
    }

    Connections {
        target: NotificationService

        // Both, and neither is redundant. processQueue() assigns
        // visibleNotifications *before* it sets the new wrapper's `popup`, so
        // the list signal arrives while the arrival still looks invisible --
        // tracking only that would skip every notification on the way in and
        // leave the shell's own timer running it. `popups` is a binding over
        // the popup flags, so it fires on the transition the list signal
        // misses.
        function onPopupsChanged() {
            root.syncTracked();
            root.refreshFocusedScreen();
        }

        function onVisibleNotificationsChanged() {
            root.syncTracked();
        }
    }

    // ---- one-at-a-time actions, for keybinds -----------------------------

    function dismissNewest() {
        const list = root.visibleList();
        return root.retire(list[list.length - 1]);
    }

    function dismissOldest() {
        const list = root.visibleList();
        return root.retire(list[0]);
    }

    // Puts the most recent notification that is not currently a line back on
    // the stack. Pressing it repeatedly walks backwards through the
    // notification centre.
    function recallOne() {
        const shown = root.visibleList();
        const all = NotificationService.notifications;
        for (let i = all.length - 1; i >= 0; i--) {
            const w = all[i];
            if (!w || shown.indexOf(w) !== -1)
                continue;
            w.popup = true;
            if (NotificationService.visibleNotifications.indexOf(w) === -1)
                NotificationService.visibleNotifications = [...NotificationService.visibleNotifications, w];
            root.syncTracked();
            return w;
        }
        return null;
    }

    // ---- built-in popup suppression -------------------------------------

    property bool suppressionApplied: false

    function screenPrefs() {
        return SettingsData.screenPreferences || ({});
    }

    function setNotificationScreens(value) {
        const next = Object.assign({}, root.screenPrefs());
        next["notifications"] = value;
        SettingsData.set("screenPreferences", next);
    }

    function applySuppression() {
        if (root.suppressionApplied)
            return;
        const current = root.screenPrefs()["notifications"] || ["all"];
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
        root.setNotificationScreens([root.suppressSentinel]);
        root.suppressionApplied = true;
        console.info("notificationLine: shipped notification popups suppressed");
    }

    function releaseSuppression() {
        const current = root.screenPrefs()["notifications"] || [];
        const isSuppressed = current.length === 1 && current[0] === root.suppressSentinel;
        if (!isSuppressed) {
            root.suppressionApplied = false;
            return;
        }
        const saved = PluginService.loadPluginData(root.pluginId, "_savedScreens", ["all"]);
        root.setNotificationScreens((saved && saved.length) ? saved : ["all"]);
        const savedFocused = PluginService.loadPluginData(root.pluginId, "_savedFocusedMonitor", false);
        if (savedFocused === true)
            SettingsData.set("notificationFocusedMonitor", true);
        root.suppressionApplied = false;
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

    // NotificationService lets four popups coexist by default and, past that
    // limit, evicts the oldest on the spot -- no timeout involved, which is
    // why a burst used to collapse to a handful of lines the instant it
    // landed while the survivors kept their configured time.
    //
    // So the shell's limit is deliberately *not* the number of lines drawn.
    // It is raised well clear of it, and the stack does its own trimming: a
    // notification past the visible count is hidden, not killed, and gets its
    // full lifetime like every other.
    readonly property int serviceCap: Math.max(24, root.maxLines * 2)

    // A Binding rather than an assignment on load with a restore on unload:
    // reloading the plugin overlaps two generations, and the outgoing one's
    // restore can land after the incoming one has already applied its value,
    // silently leaving the shell on whatever the older generation had saved.
    Binding {
        target: NotificationService
        property: "maxVisibleNotifications"
        value: root.serviceCap
        restoreMode: Binding.RestoreBindingOrValue
    }

    Component.onCompleted: {
        syncSuppression();
        syncTracked();
        console.info("notificationLine: daemon ready (ipc target 'notificationLine')");
    }

    Component.onDestruction: {
        releaseTiming();
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
            const n = root.visibleList().length;
            NotificationService.dismissAllPopups();
            return "CLEARED " + n;
        }

        function clearAll(): string {
            const n = NotificationService.notifications.length;
            NotificationService.clearAllNotifications();
            return "CLEARED " + n;
        }

        function dismiss(): string {
            return root.dismissNewest() ? "DISMISSED" : "EMPTY";
        }

        function dismissOldest(): string {
            return root.dismissOldest() ? "DISMISSED" : "EMPTY";
        }

        function recall(): string {
            const w = root.recallOne();
            return w ? ("RECALLED\t" + w.appName + "\t" + w.summary) : "NOTHING";
        }

        function suppress(state: string): string {
            const on = state !== "off" && state !== "false" && state !== "0";
            PluginService.savePluginData(root.pluginId, "suppressBuiltin", on);
            return on ? "SUPPRESSED" : "RESTORED";
        }

        function status(): string {
            const list = root.visibleList();
            const timing = root.ownsTiming ? (root.lifetime > 0 ? root.lifetime + "s" : "urgency") : "shell";
            return [root.position, "lines=" + list.length + "/" + root.maxLines, "cap=" + NotificationService.maxVisibleNotifications + "/" + root.serviceCap, "tracked=" + root.tracked.length, "timing=" + timing, "suppressed=" + root.suppressionApplied].join("\t");
        }
    }
}
