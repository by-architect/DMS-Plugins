import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "hosts.js" as Hosts

// Every watched host, in SSH Hosts' own order. The list scrolls past a point
// rather than growing the popout off the screen.
PopoutComponent {
    id: popout

    readonly property int maxBodyHeight: 620

    // Only the "x ago" texts need a clock, and only a slow one.
    property real nowMs: Date.now()

    headerText: "Hosts"
    detailsText: {
        const S = HostStatusService;
        if (S.total === 0)
            return S.allHosts.length === 0 ? "No hosts in SSH Hosts yet" : "Every host is switched off in this plugin's settings";
        const parts = [S.upCount + " of " + S.total + " online"];
        if (S.checkingCount > 0)
            parts.push("checking " + S.checkingCount);
        else if (S.lastCheckedMs > 0)
            parts.push("checked " + Hosts.agoText(S.lastCheckedMs, popout.nowMs));
        return parts.join(" · ");
    }

    headerActions: Component {
        DankActionButton {
            iconName: "refresh"
            buttonSize: 32
            iconColor: Theme.surfaceVariantText
            enabled: HostStatusService.total > 0
            tooltipText: "Check every host now"
            onClicked: HostStatusService.refreshAll(true)
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: popout.nowMs = Date.now()
    }

    Item {
        width: parent.width
        implicitHeight: Math.min(body.implicitHeight, popout.maxBodyHeight)
        height: implicitHeight

        DankFlickable {
            id: flick

            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: body.implicitHeight

            Column {
                id: body

                width: flick.width
                spacing: Theme.spacingS

                // Counted, not modelled on the array itself: the list is
                // rebuilt whenever SSH Hosts changes, and a delegate rebuilt
                // under a click would drop it.
                Repeater {
                    model: HostStatusService.hosts.length

                    HostRow {
                        required property int index
                        readonly property var entry: HostStatusService.hosts[index]

                        width: body.width
                        host: entry
                        result: entry ? HostStatusService.resultFor(entry.id) : null
                        checking: entry ? HostStatusService.isChecking(entry.id) : false
                        showStorage: HostStatusService.showStorage
                        nowMs: popout.nowMs
                    }
                }

                StyledRect {
                    width: body.width
                    height: emptyColumn.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    visible: HostStatusService.total === 0

                    Column {
                        id: emptyColumn

                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingL * 2
                        spacing: Theme.spacingXS

                        DankIcon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: "dns"
                            size: Theme.iconSize
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            text: "Hosts come from SSH Hosts: add them under Settings → Plugins → SSH Hosts and they show up here."
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }
            }
        }
    }
}
