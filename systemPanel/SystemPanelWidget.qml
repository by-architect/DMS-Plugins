import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Bar pill that toggles the fullscreen panel. Shares the "open" global var with
// the daemon, so the pill also reflects panel state opened over IPC.
PluginComponent {
    id: root

    PluginGlobalVar {
        id: openVar

        varName: "open"
        defaultValue: false
    }

    pillClickAction: function () {
        openVar.set(openVar.value !== true);
    }

    horizontalBarPill: Component {
        StyledRect {
            readonly property bool active: openVar.value === true

            // The pill's size on the bar comes from these IMPLICIT values:
            // BasePill reads implicitWidth/implicitHeight and adds the bar's
            // own widget padding around them. Setting width/height instead
            // leaves the implicit size at zero, the pill collapses to bare
            // padding, and on a vertical bar every icon ends up pressed
            // against its neighbours. `parent` here is BasePill's Loader,
            // which has no widgetThickness — that comes from root.
            implicitWidth: pillRow.implicitWidth + Theme.spacingS * 2
            implicitHeight: root.widgetThickness
            radius: height / 2
            color: active ? Theme.primaryBackground : Theme.surfaceContainerHigh

            Row {
                id: pillRow

                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: "monitor_heart"
                    size: root.iconSize
                    color: parent.parent.active ? Theme.primary : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            readonly property bool active: openVar.value === true

            // Implicit size only — see the horizontal pill. The icon sits in a
            // round well of its own, so the highlight is a circle rather than a
            // short wide slab, and the bar's own padding is what separates it
            // from its neighbours.
            implicitWidth: root.widgetThickness
            implicitHeight: root.iconSize + 10

            Rectangle {
                anchors.centerIn: parent
                width: root.iconSize + 10
                height: width
                radius: width / 2
                color: parent.active ? Theme.primaryBackground : Theme.surfaceContainerHigh

                DankIcon {
                    anchors.centerIn: parent
                    name: "monitor_heart"
                    size: root.iconSize
                    color: parent.parent.active ? Theme.primary : Theme.surfaceText
                }
            }
        }
    }
}
