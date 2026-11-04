pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets
import "emoji.js" as Emoji

// Choose a reaction.
//
// The usual few are one key away -- 1 to 8, or the arrows and Enter -- and
// anything else can be typed into the box under them, for the reaction that is
// not one of the eight: by name ("laugh", ":fire:"), with the matches shown as
// they are typed, or as an emoji pasted in. An overlay like the forward picker:
// it is a moment's choice about the conversation already open.
StyledRect {
    id: root

    // The message being reacted to, shown so a mis-selected one is caught.
    property var message: null

    // For the recently used emoji, and to remember the one picked.
    property var chatCore: null

    signal picked(string key)
    signal cancelled

    readonly property var choices: ["👍", "❤️", "😂", "🎉", "😮", "😢", "🙏", "👀"]

    // The reaction the arrows are on.
    property int highlightIndex: 0

    color: Theme.withAlpha(Theme.surfaceContainer, 0.97)
    radius: Theme.cornerRadius

    // Swallow clicks so they cannot reach the conversation behind.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
    }

    onVisibleChanged: {
        if (!visible)
            return;
        custom.text = "";
        root.highlightIndex = 0;
        root.forceActiveFocus();
    }

    function pick(index) {
        const key = root.choices[index];
        if (key)
            root.pickKey(key);
    }

    // What the box below finds for what is typed in it.
    readonly property var matches: custom.text.trim() === "" ? [] : Emoji.search(custom.text, 24)

    function pickTyped() {
        // The first match for a name; an emoji typed or pasted as it is.
        const key = root.matches.length > 0 && /^[a-z0-9_:+\-\s]+$/i.test(custom.text.trim()) ? root.matches[0] : Emoji.resolve(custom.text);
        if (key !== "")
            root.pickKey(key);
    }

    function pickKey(key) {
        root.chatCore?.noteEmoji(key);
        root.picked(key);
    }

    Keys.onPressed: event => {
        const plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier));
        if (plain && event.key >= Qt.Key_1 && event.key <= Qt.Key_8) {
            root.pick(event.key - Qt.Key_1);
            event.accepted = true;
            return;
        }
        switch (event.key) {
        case Qt.Key_Left:
            root.highlightIndex = Math.max(0, root.highlightIndex - 1);
            event.accepted = true;
            break;
        case Qt.Key_Right:
            root.highlightIndex = Math.min(root.choices.length - 1, root.highlightIndex + 1);
            event.accepted = true;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.pick(root.highlightIndex);
            event.accepted = true;
            break;
        case Qt.Key_Tab:
        case Qt.Key_Down:
            custom.forceActiveFocus();
            event.accepted = true;
            break;
        case Qt.Key_Escape:
            root.cancelled();
            event.accepted = true;
            break;
        }
    }

    Column {
        anchors.centerIn: parent
        width: Math.min(440, parent.width - Theme.spacingXL * 2)
        spacing: Theme.spacingM

        Row {
            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - closeButton.width - Theme.spacingS
                text: I18n.tr("React")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            DankActionButton {
                id: closeButton
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 28
                iconName: "close"
                iconColor: Theme.surfaceVariantText
                onClicked: root.cancelled()
            }
        }

        StyledRect {
            width: parent.width
            height: preview.implicitHeight + Theme.spacingS * 2
            visible: preview.text !== ""
            radius: Theme.cornerRadius / 2
            color: Theme.withAlpha(Theme.surfaceVariantText, 0.12)

            StyledText {
                id: preview
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingS
                text: root.message?.text || root.message?.fileName || ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingS

            Repeater {
                model: root.choices

                StyledRect {
                    id: choice

                    required property string modelData
                    required property int index

                    readonly property bool highlighted: index === root.highlightIndex && root.activeFocus

                    width: 46
                    height: 52
                    radius: Theme.cornerRadius
                    color: choiceArea.containsMouse || choice.highlighted ? Theme.surfaceHover : Theme.withAlpha(Theme.surfaceVariantText, 0.08)
                    border.color: choice.highlighted ? Theme.primary : "transparent"
                    border.width: choice.highlighted ? 2 : 0

                    StyledText {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -3
                        text: choice.modelData
                        font.pixelSize: Theme.fontSizeLarge + 4
                    }

                    // The key that picks it.
                    StyledText {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottomMargin: 2
                        text: String(choice.index + 1)
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                    }

                    MouseArea {
                        id: choiceArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pick(choice.index)
                    }
                }
            }
        }

        DankTextField {
            id: custom
            width: parent.width
            placeholderText: I18n.tr("Or search: laugh, fire, ok… then Enter")
            leftIconName: "add_reaction"

            onAccepted: root.pickTyped()
            Keys.onEscapePressed: event => {
                root.cancelled();
                event.accepted = true;
            }
            Keys.onUpPressed: event => {
                root.forceActiveFocus();
                event.accepted = true;
            }
        }

        // What the typed name matches, the first being what Enter picks.
        Flow {
            width: parent.width
            spacing: Theme.spacingXS
            visible: root.matches.length > 0

            Repeater {
                model: root.matches

                StyledRect {
                    id: match

                    required property string modelData
                    required property int index

                    width: 40
                    height: 40
                    radius: Theme.cornerRadius / 2
                    color: matchArea.containsMouse ? Theme.surfaceHover : (match.index === 0 ? Theme.withAlpha(Theme.primary, 0.14) : "transparent")

                    StyledText {
                        anchors.centerIn: parent
                        text: match.modelData
                        font.pixelSize: Theme.fontSizeLarge + 2
                    }

                    MouseArea {
                        id: matchArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pickKey(match.modelData)
                    }
                }
            }
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: I18n.tr("1–8 or ← → and Enter to choose  ·  Tab to type your own  ·  Esc to close")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }
}
