import QtQuick
import qs.Common
import qs.Widgets

// The foot of a conversation you have been invited to and not answered.
//
// It stands where the composer stands, rather than beside it: a conversation
// you have not joined cannot be written to, so a text field here would only
// produce a message the service refuses. Answering the invitation is the one
// thing there is to do, so it is the only thing offered.
Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    // The invitation line the provider sent, shown as the prompt. Providers
    // word it themselves -- "Ada invited you to this room" -- because only they
    // know what being invited means on their service.
    property string prompt: ""

    signal accepted
    signal declined

    implicitHeight: 64
    height: implicitHeight

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.2
    }

    StyledText {
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingM
        anchors.right: actions.left
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        text: root.prompt !== "" ? root.prompt : I18n.tr("You have been invited to this conversation")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        elide: Text.ElideRight
        maximumLineCount: 2
        wrapMode: Text.WordWrap
    }

    Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        DankButton {
            text: I18n.tr("Decline")
            backgroundColor: "transparent"
            textColor: Theme.surfaceText
            onClicked: root.declined()
        }

        DankButton {
            text: I18n.tr("Join")
            iconName: "check"
            backgroundColor: Theme.primary
            textColor: Theme.onPrimary
            onClicked: root.accepted()
        }
    }
}
