pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// Choose where a message is going.
//
// Forwarding sends into a different conversation, so the destination is picked
// explicitly -- there is no sensible default, and guessing means sending to the
// wrong person.
StyledRect {
    id: root

    // The chat core, handed down from the plugin daemon. It was a shell
    // singleton before this became a plugin, which is why it used to be
    // reachable from anywhere without being passed.
    //
    // Deliberately not called "chat": several of these components already use
    // that name for the conversation being shown, which is a different thing.
    required property var chatCore

    property var source: null

    signal picked(string provider, string chatId)
    signal cancelled

    color: Theme.withAlpha(Theme.surfaceContainer, 0.97)
    radius: Theme.cornerRadius

    // Swallow clicks so they cannot reach the conversation behind.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
    }

    onVisibleChanged: {
        if (visible) {
            filter.text = "";
            root.highlightIndex = root.targets.length > 0 ? 0 : -1;
            filter.forceActiveFocus();
        }
    }

    // The destination the keyboard is on. The filter keeps focus, and the
    // arrows and Enter choose from the list under it: forwarding is reached
    // from a key, and finishing it used to need the mouse.
    property int highlightIndex: -1

    readonly property var targets: {
        const query = filter.text.trim().toLowerCase();
        const digits = query.replace(/\D/g, "");
        const out = [];
        for (let i = 0; i < root.chatCore.chats.length; i++) {
            const chat = root.chatCore.chats[i];
            // Forwarding to the conversation it came from is a no-op the user
            // never means.
            if (chat.provider === root.chatCore.activeProvider && chat.id === root.chatCore.activeChatId)
                continue;
            // Somewhere this cannot arrive is not offered, rather than offered
            // and failing once chosen: a provider that cannot send, or an
            // invitation that has not been joined.
            if (!root.chatCore.supports(chat.provider, "send") || root.chatCore.isInvite(chat))
                continue;
            if (query !== "" && !root.matches(chat, query, digits))
                continue;
            out.push(chat);
        }
        return out;
    }

    onTargetsChanged: {
        if (root.highlightIndex >= root.targets.length || (root.highlightIndex < 0 && root.targets.length > 0))
            root.highlightIndex = root.targets.length > 0 ? 0 : -1;
    }

    // matches is the name, the subject, or anything the conversation answers
    // to -- a number in any formatting, an address.
    function matches(chat, query, digits) {
        if ((chat.name || "").toLowerCase().indexOf(query) !== -1)
            return true;
        if ((chat.subject || "").toLowerCase().indexOf(query) !== -1)
            return true;
        const handles = chat.handles || [];
        for (let i = 0; i < handles.length; i++) {
            if (handles[i].toLowerCase().indexOf(query) !== -1)
                return true;
            if (digits.length >= 4 && handles[i].replace(/\D/g, "").indexOf(digits) !== -1)
                return true;
        }
        return false;
    }

    function moveHighlight(step) {
        const count = root.targets.length;
        if (count === 0)
            return;
        root.highlightIndex = Math.max(0, Math.min(count - 1, root.highlightIndex + step));
        targetList.positionViewAtIndex(root.highlightIndex, ListView.Contain);
    }

    function pickHighlighted() {
        const chat = root.targets[root.highlightIndex];
        if (chat)
            root.picked(chat.provider, chat.id);
    }

    Keys.onEscapePressed: event => {
        root.cancelled();
        event.accepted = true;
    }

    Column {
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingS

        Row {
            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - closeButton.width - Theme.spacingS
                text: I18n.tr("Forward to")
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

        // What is being forwarded, so the user can see they picked the right
        // message before choosing a destination.
        StyledRect {
            width: parent.width
            height: preview.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius / 2
            color: Theme.withAlpha(Theme.surfaceVariantText, 0.12)

            StyledText {
                id: preview
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingS
                text: root.source?.text ?? ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }
        }

        DankTextField {
            id: filter
            width: parent.width
            placeholderText: I18n.tr("Search conversations")
            leftIconName: "search"

            Keys.onDownPressed: event => {
                root.moveHighlight(1);
                event.accepted = true;
            }
            Keys.onUpPressed: event => {
                root.moveHighlight(-1);
                event.accepted = true;
            }
            onAccepted: root.pickHighlighted()
        }

        // The list and its empty state share what is left of the height; the
        // empty state used to sit after a list that had already taken all of
        // it, below the bottom edge.
        Item {
            width: parent.width
            height: parent.height - parent.spacing * 3 - closeButton.height - preview.height - Theme.spacingS * 2 - filter.height

            DankListView {
                id: targetList
                anchors.fill: parent
                clip: true
                model: root.targets
                spacing: Theme.spacingXS

                delegate: ChatCandidateRow {
                    required property var modelData
                    required property int index

                    width: ListView.view.width
                    highlighted: index === root.highlightIndex
                    candidate: ({
                            "name": modelData.name || modelData.subject || modelData.id,
                            "chatId": modelData.id,
                            "provider": modelData.provider,
                            "providerName": root.chatCore.providerById(modelData.provider)?.name ?? modelData.provider,
                            "isGroup": modelData.isGroup,
                            "unread": 0
                        })

                    onChosen: root.picked(modelData.provider, modelData.id)
                }
            }

            StyledText {
                anchors.centerIn: parent
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: root.targets.length === 0
                text: filter.text.trim() !== "" ? I18n.tr("No conversation matches") : I18n.tr("No other conversations")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }
}
