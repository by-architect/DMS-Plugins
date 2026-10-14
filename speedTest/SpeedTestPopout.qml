import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "speedtest.js" as Speed

// Top to bottom: what is happening now (a test running, the last one
// failing), the last result's three numbers, where it was measured, and the
// tests before it.
PopoutComponent {
    id: popout

    readonly property bool onScreen: !!parentPopout && !!parentPopout.shouldBeVisible
    readonly property var last: SpeedTestService.last
    readonly property var history: SpeedTestService.history
    // Ages are read off this, ticking every second while a test runs (for its
    // elapsed time) and every half minute otherwise, only while on screen.
    property real nowMs: Date.now()

    Timer {
        interval: SpeedTestService.running ? 1000 : 30000
        repeat: true
        running: popout.onScreen
        triggeredOnStart: true
        onTriggered: popout.nowMs = Date.now()
    }

    headerText: "Speed test"
    detailsText: {
        const s = SpeedTestService;
        const parts = [];
        parts.push(popout.last ? "last test " + Speed.agoText(popout.last.ms, popout.nowMs) : "no test yet");
        if (s.intervalMinutes <= 0)
            parts.push("automatic tests off");
        else if (s.offline)
            parts.push("waiting for a network");
        else if (!s.running && s.nextDueMs > 0)
            parts.push("next " + Speed.inText(s.nextDueMs, popout.nowMs));
        return parts.join(" · ");
    }

    // A label with its value under it, for the three big numbers.
    component Figure: Column {
        id: figure

        property string label: ""
        property string value: "--"
        property string unit: ""
        property color valueColor: Theme.surfaceText

        spacing: 2

        StyledText {
            text: figure.label
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
        }

        Row {
            spacing: 4

            StyledText {
                id: figureValue

                text: figure.value
                font.pixelSize: Theme.fontSizeXLarge + 4
                font.weight: Font.Bold
                font.features: ({
                        "tnum": 1
                    })
                color: figure.valueColor
                wrapMode: Text.NoWrap
            }

            StyledText {
                anchors.baseline: figureValue.baseline
                text: figure.unit
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.NoWrap
            }
        }
    }

    // One "label  value" line in the details card; the value wraps rather
    // than being cut.
    component Detail: Item {
        id: detail

        property string label: ""
        property string value: ""

        width: parent ? parent.width : 0
        height: Math.max(detailLabel.implicitHeight, detailValue.implicitHeight)
        visible: value.length > 0

        StyledText {
            id: detailLabel

            width: 72
            text: detail.label
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
        }

        StyledText {
            id: detailValue

            anchors.left: detailLabel.right
            anchors.right: parent.right
            anchors.leftMargin: Theme.spacingS
            text: detail.value
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            elide: Text.ElideNone
        }
    }

    Column {
        id: body

        width: parent.width
        spacing: Theme.spacingS

        // --------------------------------------------------- now: running
        StyledRect {
            width: body.width
            height: runningRow.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.12)
            visible: SpeedTestService.running

            Row {
                id: runningRow

                x: Theme.spacingM
                y: Theme.spacingS
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingS

                DankSpinner {
                    id: runSpinner

                    anchors.verticalCenter: parent.verticalCenter
                    size: Theme.iconSize - 4
                    running: SpeedTestService.running
                }

                StyledText {
                    width: parent.width - runSpinner.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Testing for " + Math.max(0, Math.round((popout.nowMs - SpeedTestService.startedMs) / 1000)) + " s: finding a server, then a download and an upload. Usually under a minute."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }
            }
        }

        // ---------------------------------------------- now: last failed
        StyledRect {
            width: body.width
            height: failRow.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.error, 0.12)
            visible: SpeedTestService.lastFailed && !SpeedTestService.running

            Row {
                id: failRow

                x: Theme.spacingM
                y: Theme.spacingS
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingS

                DankIcon {
                    id: failIcon

                    anchors.verticalCenter: parent.verticalCenter
                    name: "error"
                    size: Theme.iconSize - 4
                    color: Theme.error
                }

                StyledText {
                    width: parent.width - failIcon.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    text: "The test " + Speed.agoText(SpeedTestService.lastAttemptMs, popout.nowMs) + " failed: " + SpeedTestService.lastError + (SpeedTestService.intervalMinutes > 0 && SpeedTestService.nextDueMs > 0 ? ". Trying again " + Speed.inText(SpeedTestService.nextDueMs, popout.nowMs) + "." : "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    elide: Text.ElideNone
                }
            }
        }

        // ------------------------------------------------- the last result
        StyledRect {
            width: body.width
            height: figures.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Row {
                id: figures

                readonly property real third: (width - spacing * 2) / 3

                x: Theme.spacingM
                y: Theme.spacingM
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingM

                Figure {
                    width: figures.third
                    label: "Download"
                    value: popout.last ? Speed.shortMbps(popout.last.down).replace("G", "") : "--"
                    unit: popout.last && popout.last.down >= 1000 ? "Gbit/s" : "Mbit/s"
                    valueColor: SpeedTestService.slow ? Theme.tempWarning : Theme.primary
                }

                Figure {
                    width: figures.third
                    label: "Upload"
                    value: popout.last ? Speed.shortMbps(popout.last.up).replace("G", "") : "--"
                    unit: popout.last && popout.last.up >= 1000 ? "Gbit/s" : "Mbit/s"
                    valueColor: Theme.secondary
                }

                Figure {
                    width: figures.third
                    label: popout.last && popout.last.jitter >= 0 ? "Ping · jitter " + popout.last.jitter.toFixed(1) : "Ping"
                    value: popout.last && popout.last.ping >= 0 ? (popout.last.ping >= 100 ? Math.round(popout.last.ping) + "" : popout.last.ping.toFixed(1)) : "--"
                    unit: "ms"
                }
            }
        }

        // --------------------------------------------- where it was measured
        StyledRect {
            width: body.width
            height: details.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh
            visible: !!popout.last

            Column {
                id: details

                x: Theme.spacingM
                y: Theme.spacingM
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingXS

                Detail {
                    label: "Server"
                    value: popout.last ? [popout.last.server, popout.last.location].filter(s => !!s).join(" · ") : ""
                }

                Detail {
                    label: "Provider"
                    value: popout.last ? [popout.last.isp, popout.last.ip].filter(s => !!s).join(" · ") : ""
                }

                Detail {
                    label: "Network"
                    value: popout.last ? popout.last.network || "" : ""
                }

                Detail {
                    label: "Tested"
                    value: popout.last ? Speed.clockText(popout.last.ms) + " with " + popout.last.tool + (popout.last.loss >= 0 ? " · " + popout.last.loss.toFixed(1) + "% packets lost" : "") : ""
                }
            }
        }

        // --------------------------------------------------------- history
        StyledRect {
            width: body.width
            height: historyColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh
            visible: popout.history.length > 1

            Column {
                id: historyColumn

                x: Theme.spacingM
                y: Theme.spacingM
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingS

                Item {
                    width: historyColumn.width
                    height: historyCaption.implicitHeight

                    StyledText {
                        id: historyCaption

                        text: "Last " + popout.history.length + " tests"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                        wrapMode: Text.NoWrap
                    }

                    Row {
                        anchors.right: parent.right
                        spacing: Theme.spacingM

                        StyledText {
                            text: "━ download"
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.primary
                            wrapMode: Text.NoWrap
                        }

                        StyledText {
                            text: "━ upload"
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.secondary
                            wrapMode: Text.NoWrap
                        }
                    }
                }

                // Both lines on one scale, so upload sits below download the
                // way it does in the numbers.
                DankSparkline {
                    width: historyColumn.width
                    height: 56
                    values: popout.history.map(r => Math.max(0, r.down))
                    secondaryValues: popout.history.map(r => Math.max(0, r.up))
                    minimum: 0
                    maximum: Math.max(1, ...popout.history.map(r => Math.max(r.down, r.up))) * 1.1
                    historyLength: SpeedTestService.historyLimit
                    lineColor: Theme.primary
                    secondaryLineColor: Theme.secondary
                    fillOpacity: 0.12
                }

                // The newest few, as numbers.
                Repeater {
                    model: popout.history.slice(-6).reverse()

                    Item {
                        id: histRow

                        required property var modelData

                        width: historyColumn.width
                        height: histText.implicitHeight

                        StyledText {
                            id: histWhen

                            width: 84
                            text: Speed.clockText(histRow.modelData.ms)
                            font.pixelSize: Theme.fontSizeSmall
                            font.features: ({
                                    "tnum": 1
                                })
                            color: Theme.surfaceVariantText
                            wrapMode: Text.NoWrap
                        }

                        StyledText {
                            id: histText

                            anchors.left: histWhen.right
                            anchors.right: parent.right
                            text: "↓ " + Speed.mbpsText(histRow.modelData.down) + "   ↑ " + Speed.mbpsText(histRow.modelData.up) + "   " + Speed.msText(histRow.modelData.ping) + (histRow.modelData.network ? "   " + histRow.modelData.network : "")
                            font.pixelSize: Theme.fontSizeSmall
                            font.features: ({
                                    "tnum": 1
                                })
                            color: Theme.surfaceText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            elide: Text.ElideNone
                        }
                    }
                }
            }
        }

        // --------------------------------------------------------- actions
        Item {
            width: body.width
            height: runButton.height

            DankButton {
                id: runButton

                anchors.left: parent.left
                text: SpeedTestService.running ? "Testing…" : "Run now"
                iconName: "speed"
                enabled: !SpeedTestService.running
                onClicked: SpeedTestService.run("manual")
            }

            StyledText {
                anchors.left: runButton.right
                anchors.leftMargin: Theme.spacingM
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: SpeedTestService.intervalMinutes > 0 ? "Every " + (SpeedTestService.intervalMinutes % 60 === 0 ? (SpeedTestService.intervalMinutes / 60) + " h" : SpeedTestService.intervalMinutes + " min") + " · right-click the pill to test now" : "Automatic tests are off · right-click the pill to test now"
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.outline
                wrapMode: Text.WordWrap
            }
        }
    }
}
