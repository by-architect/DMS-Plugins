import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "procstat.js" as Stat

// Top to bottom, from the number on the pill to what is behind it: the total
// with its last two minutes, memory, every core, then the processes.
PopoutComponent {
    id: popout

    // DMS keeps a closed popout's tree loaded for a fast re-open, so this item
    // existing does not mean it is on screen. The process list -- the one part
    // that costs a `ps` run -- follows the popout's own visibility instead.
    readonly property bool onScreen: !!parentPopout && !!parentPopout.shouldBeVisible
    property bool _counted: false

    property int hoveredCore: -1

    // Shared by the column titles and every ProcessRow, so they line up.
    readonly property int cpuColumnWidth: 56
    readonly property int memColumnWidth: 44
    readonly property int killColumnWidth: 30
    readonly property color cpuColor: ProcessWidgetService.colorFor(ProcessWidgetService.cpu, Theme.primary)
    readonly property var memory: ProcessWidgetService.memory
    readonly property var load: ProcessWidgetService.load

    function _syncViewer() {
        if (onScreen === _counted)
            return;
        _counted = onScreen;
        ProcessWidgetService.viewers = Math.max(0, ProcessWidgetService.viewers + (onScreen ? 1 : -1));
    }

    onOnScreenChanged: _syncViewer()
    Component.onCompleted: _syncViewer()
    Component.onDestruction: {
        if (_counted) {
            _counted = false;
            ProcessWidgetService.viewers = Math.max(0, ProcessWidgetService.viewers - 1);
        }
    }

    headerText: "CPU"
    detailsText: {
        const n = ProcessWidgetService.coreCount;
        const cores = n === 1 ? "1 core" : n + " cores";
        if (!popout.load)
            return n > 0 ? cores : "Reading /proc/stat…";
        return cores + " · load " + Stat.loadText(popout.load);
    }

    // A bar with its label and value above it, for memory and swap.
    component Meter: Column {
        id: meter

        property string label: ""
        property string valueText: ""
        property real fraction: 0
        property color barColor: Theme.primary

        spacing: 4

        Item {
            width: meter.width
            height: meterLabel.implicitHeight

            StyledText {
                id: meterLabel

                text: meter.label
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.right: parent.right
                text: meter.valueText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }

        Rectangle {
            width: meter.width
            height: 4
            radius: 2
            color: Theme.surfaceContainerHighest

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, meter.fraction))
                height: parent.height
                radius: parent.radius
                color: meter.barColor
            }
        }
    }

    Column {
        id: body

        width: parent.width
        spacing: Theme.spacingS

        // ------------------------------------------------ total and memory
        StyledRect {
            width: body.width
            height: summary.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Column {
                id: summary

                x: Theme.spacingM
                y: Theme.spacingM
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingM

                Row {
                    width: summary.width
                    spacing: Theme.spacingM

                    Column {
                        id: bigNumber

                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(totalText.implicitWidth, totalCaption.implicitWidth)

                        StyledText {
                            id: totalText

                            text: Stat.percentText(ProcessWidgetService.cpu)
                            font.pixelSize: Theme.fontSizeXLarge + 8
                            font.weight: Font.Bold
                            font.features: ({
                                    "tnum": 1
                                })
                            color: popout.cpuColor
                        }

                        StyledText {
                            id: totalCaption

                            text: "CPU in use"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    // The last historyLimit readings: two minutes at the
                    // default interval, starting empty after the shell starts.
                    DankSparkline {
                        width: summary.width - bigNumber.width - parent.spacing
                        height: 52
                        anchors.verticalCenter: parent.verticalCenter
                        values: ProcessWidgetService.history
                        minimum: 0
                        maximum: 100
                        historyLength: ProcessWidgetService.historyLimit
                        lineColor: popout.cpuColor
                        fillOpacity: 0.16
                    }
                }

                Meter {
                    width: summary.width
                    label: "Memory"
                    valueText: popout.memory ? Stat.formatKb(popout.memory.usedKb) + " of " + Stat.formatKb(popout.memory.totalKb) : "…"
                    fraction: popout.memory ? popout.memory.usedKb / popout.memory.totalKb : 0
                    barColor: Theme.primary
                }

                Meter {
                    width: summary.width
                    visible: !!popout.memory && popout.memory.swapTotalKb > 0
                    label: "Swap"
                    valueText: popout.memory ? Stat.formatKb(popout.memory.swapUsedKb) + " of " + Stat.formatKb(popout.memory.swapTotalKb) : ""
                    fraction: popout.memory && popout.memory.swapTotalKb > 0 ? popout.memory.swapUsedKb / popout.memory.swapTotalKb : 0
                    barColor: Theme.secondary
                }
            }
        }

        // ------------------------------------------------------- per core
        StyledRect {
            width: body.width
            height: coresColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh
            visible: ProcessWidgetService.coreCount > 0

            Column {
                id: coresColumn

                x: Theme.spacingM
                y: Theme.spacingM
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingS

                Item {
                    width: coresColumn.width
                    height: coresCaption.implicitHeight

                    StyledText {
                        id: coresCaption

                        text: "Per core"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                    }

                    // The hovered core, or else the busiest one: 22 bars
                    // cannot each carry a label.
                    StyledText {
                        anchors.right: parent.right
                        text: {
                            const cores = ProcessWidgetService.cores;
                            const c = popout.hoveredCore >= 0 && popout.hoveredCore < cores.length ? cores[popout.hoveredCore] : null;
                            if (c)
                                return "cpu" + c.id + "  " + Stat.percentText(c.usage);
                            const b = ProcessWidgetService.busiest;
                            return b ? "busiest: cpu" + b.id + "  " + Stat.percentText(b.usage) : "";
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        font.features: ({
                                "tnum": 1
                            })
                        color: Theme.surfaceText
                    }
                }

                Row {
                    id: strip

                    readonly property int count: ProcessWidgetService.coreCount
                    readonly property real barWidth: count > 0 ? (width - spacing * (count - 1)) / count : 0

                    width: coresColumn.width
                    height: 44
                    spacing: count > 32 ? 1 : 2

                    // Counted rather than modelled on the array: the service
                    // replaces that array every sample, and a delegate rebuilt
                    // every two seconds would restart its animation from zero.
                    Repeater {
                        model: strip.count

                        Item {
                            id: bar

                            required property int index
                            readonly property var core: ProcessWidgetService.cores[index]
                            readonly property real usage: core && core.usage >= 0 ? core.usage : 0

                            width: strip.barWidth
                            height: strip.height

                            Rectangle {
                                anchors.fill: parent
                                radius: Math.min(3, width / 2)
                                color: Theme.surfaceContainerHighest
                            }

                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                height: Math.max(1, parent.height * bar.usage / 100)
                                radius: Math.min(3, width / 2)
                                color: ProcessWidgetService.colorFor(bar.usage, Theme.primary)
                                opacity: popout.hoveredCore === bar.index ? 1 : 0.85

                                Behavior on height {
                                    NumberAnimation {
                                        duration: Theme.shortDuration
                                        easing.type: Theme.standardEasing
                                    }
                                }
                            }

                            HoverHandler {
                                onHoveredChanged: {
                                    if (hovered)
                                        popout.hoveredCore = bar.index;
                                    else if (popout.hoveredCore === bar.index)
                                        popout.hoveredCore = -1;
                                }
                            }
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------- processes
        StyledRect {
            width: body.width
            height: procColumn.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Column {
                id: procColumn

                x: Theme.spacingS
                y: Theme.spacingS
                width: parent.width - Theme.spacingS * 2
                spacing: 2

                // Column titles, lined up with ProcessRow's own columns.
                Item {
                    width: procColumn.width
                    height: procCaption.implicitHeight + Theme.spacingXS

                    StyledText {
                        id: procCaption

                        x: Theme.spacingS
                        text: "Top processes"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: popout.killColumnWidth + Theme.spacingS
                        spacing: Theme.spacingS

                        StyledText {
                            width: popout.cpuColumnWidth
                            horizontalAlignment: Text.AlignRight
                            text: "CPU"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            width: popout.memColumnWidth
                            horizontalAlignment: Text.AlignRight
                            text: "MEM"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                StyledText {
                    width: procColumn.width
                    leftPadding: Theme.spacingS
                    visible: ProcessWidgetService.processes.length === 0 || ProcessWidgetService.listError !== ""
                    text: ProcessWidgetService.listError !== "" ? "Could not list processes: " + ProcessWidgetService.listError : (ProcessWidgetService.everListed ? "No processes" : "Listing processes…")
                    font.pixelSize: Theme.fontSizeSmall
                    color: ProcessWidgetService.listError !== "" ? Theme.error : Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                DankFlickable {
                    id: procFlick

                    width: procColumn.width
                    height: Math.min(rows.implicitHeight, 360)
                    clip: true
                    contentWidth: width
                    contentHeight: rows.implicitHeight
                    interactive: contentHeight > height

                    Column {
                        id: rows

                        width: procFlick.width

                        // Counted, for the same reason as the core bars:
                        // every refresh is a new array, and rows bound through
                        // the index are updated in place instead of rebuilt.
                        Repeater {
                            model: ProcessWidgetService.processes.length

                            ProcessRow {
                                required property int index

                                width: rows.width
                                entry: ProcessWidgetService.processes[index]
                                cpuWidth: popout.cpuColumnWidth
                                memWidth: popout.memColumnWidth
                                killWidth: popout.killColumnWidth
                            }
                        }
                    }
                }

                StyledText {
                    width: procColumn.width
                    leftPadding: Theme.spacingS
                    topPadding: Theme.spacingXS
                    visible: ProcessWidgetService.processes.length > 0
                    text: "Click a row to copy its PID · ✕ asks it to exit (SIGTERM), right-click ✕ to force it (SIGKILL) · CPU is ps's average since each process started"
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.outline
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
