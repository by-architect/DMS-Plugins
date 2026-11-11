import QtQuick
import Quickshell
import qs.Modules.Plugins

// Puts the bar on the left edge of every screen -- or of the one named in
// the settings -- while it is shown. Variants creates the windows, which is
// what lets each become a layer surface: a PanelWindow declared inline in
// this component never would.
PluginComponent {
    id: root

    readonly property string screenName: pluginData.screen ?? ""

    readonly property var screens: {
        if (!MatrixBarService.shown)
            return [];
        const all = Quickshell.screens;
        if (!root.screenName)
            return all;
        const one = all.filter(s => s.name === root.screenName);
        // A screen that is not plugged in right now: every screen, rather
        // than no bar at all.
        return one.length > 0 ? one : all;
    }

    Variants {
        model: root.screens

        delegate: MatrixBarWindow {}
    }
}
