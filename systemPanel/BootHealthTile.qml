import QtQuick
import qs.Common
import qs.Widgets
import "util.js" as Util

PanelTile {
    id: root

    required property var data

    title: "Boot Health"
    iconName: "restart_alt"
    busy: !data.bootsRan && data.bootList.length === 0
    empty: data.bootList.length === 0 && data.bootsRan
    emptyText: "No boot records"
    error: data.bootsError
    statusText: data.uncleanBootCount > 0 ? (data.uncleanBootCount + " unclean") : "all clean"
    statusColor: data.uncleanBootCount > 0 ? Theme.error : Theme.success
    footerText: "unclean = no graceful systemd-shutdown recorded"

    Repeater {
        model: root.data.bootList

        Column {
            required property var modelData

            width: parent ? parent.width : 0
            spacing: 0

            TileRow {
                readonly property bool bad: modelData.status === "unclean"
                readonly property bool running: modelData.status === "running"

                primary: (running ? "current boot" : ("boot " + modelData.index)) + "  ·  " + (bad ? "UNCLEAN" : (running ? "running" : "clean shutdown"))
                secondary: "ran " + Util.fmtDuration(modelData.seconds) + (running ? "" : ("  ·  until " + Util.fmtAbs(modelData.last)))
                trailing: Util.relTime(modelData.first)
                trailingSub: Util.fmtAbs(modelData.first)
                dotColor: bad ? Theme.error : (running ? Theme.success : Theme.primary)
                primaryColor: bad ? Theme.error : Theme.surfaceText
                iconName: bad ? "bolt" : (running ? "play_circle" : "")
            }

            // Error context is only fetched for boots that ended badly.
            Repeater {
                model: modelData.status === "unclean" && modelData.errors ? modelData.errors : []

                StyledText {
                    required property var modelData

                    width: parent ? parent.width - Theme.spacingL * 2 : 0
                    x: Theme.spacingL + 4
                    text: "└ " + modelData
                    font.pixelSize: Theme.fontSizeSmall - 2
                    color: Theme.error
                    opacity: 0.85
                    elide: Text.ElideRight
                    bottomPadding: 2
                }
            }
        }
    }
}
