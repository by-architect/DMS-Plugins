pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// The popout's body: either a disambiguation list, a no-match message, or one
// conversation.
FocusScope {
    id: root

    // The chat core, handed down from the plugin daemon. It was a shell
    // singleton before this became a plugin, which is why it used to be
    // reachable from anywhere without being passed.
    //
    // Deliberately not called "chat": several of these components already use
    // that name for the conversation being shown, which is a different thing.
    required property var chatCore

    signal closeRequested

    // Whether the popout is open, for the composer's drafts.
    property bool onScreen: true

    // The popout this is the body of, handed in by it rather than found by
    // walking up the parent chain, which breaks whenever the modal's internal
    // structure changes.
    //
    // It used to be read from PopoutService.chatPopout, which only the forked
    // shell had. Stock DMS has no such property, so this was always undefined:
    // a name matching two people opened neither and never asked which, a name
    // matching nobody said nothing, and a candidate clicked did nothing.
    property var popout: null
    readonly property var candidates: popout?.candidates ?? []
    readonly property string resolveError: popout?.resolveError ?? ""
    readonly property bool resolving: popout?.resolving ?? false

    readonly property bool hasOverlay: conversation.hasOverlay

    readonly property bool showingConversation: !resolving && candidates.length === 0 && resolveError === ""

    // Whether the manager streams state to this is the daemon's business: it
    // follows the popout being open, see ChatManagerDaemon.
    Component.onCompleted: {
        // Built with the conversation already open -- reopening one, or a
        // window that outlived it -- means there is no change to follow, so it
        // is asked for outright.
        if (root.conversationReady)
            Qt.callLater(root.takeFocus);
    }

    // Whether there is a conversation here to type into.
    readonly property bool conversationReady: root.showingConversation && root.chatCore.hasActiveChat

    function takeFocus() {
        // Straight to the composer: a chat opens ready to be written in, and
        // every shortcut is designed around the text field holding focus.
        if (root.conversationReady)
            conversation.takeFocus();
        else
            root.forceActiveFocus();
    }

    // The conversation almost always arrives after the popout does -- it is
    // opened on the next turn of the event loop, once this content exists --
    // so whatever asked for focus as the popout appeared found nothing to give
    // it to and left it on this scope, where typing goes nowhere. Following the
    // conversation appearing is what makes it land in the text field.
    onConversationReadyChanged: {
        if (root.conversationReady)
            Qt.callLater(root.takeFocus);
    }

    // Focus handed to this scope -- by the modal as it loads its contents, or
    // by a click landing on nothing -- is passed on to the conversation, which
    // is the only thing here that anybody types into.
    onActiveFocusChanged: {
        if (root.activeFocus && root.conversationReady)
            Qt.callLater(root.takeFocus);
    }

    Keys.onEscapePressed: event => {
        root.closeRequested();
        event.accepted = true;
    }

    // The candidate the keyboard is on, when a query matched several. The
    // popout is reached from a keybind, so choosing who was meant should not
    // need the mouse either.
    property int candidateIndex: 0
    onCandidatesChanged: root.candidateIndex = 0

    Keys.onPressed: event => {
        if (root.resolving || root.candidates.length === 0)
            return;
        switch (event.key) {
        case Qt.Key_Down:
        case Qt.Key_Up:
            root.candidateIndex = Math.max(0, Math.min(root.candidates.length - 1, root.candidateIndex + (event.key === Qt.Key_Down ? 1 : -1)));
            candidateList.positionViewAtIndex(root.candidateIndex, ListView.Contain);
            event.accepted = true;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter: {
            const chosen = root.candidates[root.candidateIndex];
            if (chosen)
                root.popout?.openResolved(chosen.provider, chosen.chatId);
            event.accepted = true;
            break;
        }
        }
    }

    DankSpinner {
        anchors.centerIn: parent
        width: 32
        height: 32
        visible: root.resolving
    }

    // ------------------------------------------------------------- no match

    Column {
        anchors.centerIn: parent
        width: parent.width - Theme.spacingXL * 2
        spacing: Theme.spacingM
        visible: !root.resolving && root.resolveError !== "" && root.candidates.length === 0

        DankIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "search_off"
            size: Theme.iconSizeLarge
            color: Theme.surfaceVariantText
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.resolveError
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: I18n.tr("Try a name, a phone number, or provider:chatId.")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    // -------------------------------------------------------- disambiguation

    // Shown when a query matched more than one conversation. Deliberately a
    // choice rather than a guess: opening the wrong chat means sending a
    // message to the wrong person.
    Column {
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingS
        visible: !root.resolving && root.candidates.length > 0

        StyledText {
            width: parent.width
            text: I18n.tr("Which conversation?")
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            id: matchCount
            width: parent.width
            text: I18n.tr("%1 conversations match.").arg(root.candidates.length)
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        DankListView {
            id: candidateList
            width: parent.width
            height: parent.height - parent.spacing * 3 - matchCount.height - Theme.fontSizeLarge * 1.4
            clip: true
            model: root.candidates
            spacing: Theme.spacingXS

            delegate: ChatCandidateRow {
                required property var modelData
                required property int index

                width: ListView.view.width
                candidate: modelData
                highlighted: index === root.candidateIndex

                onChosen: root.popout?.openResolved(modelData.provider, modelData.chatId)
            }
        }
    }

    // ------------------------------------------------------- the conversation

    ConversationView {

        chatCore: root.chatCore
        id: conversation
        anchors.fill: parent
        anchors.margins: Theme.spacingS
        onScreen: root.onScreen
        visible: root.showingConversation && root.chatCore.hasActiveChat
    }

    StyledText {
        anchors.centerIn: parent
        visible: root.showingConversation && !root.chatCore.hasActiveChat
        text: I18n.tr("No conversation open")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
    }
}
