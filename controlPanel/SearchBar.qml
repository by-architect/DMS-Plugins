import QtQuick
import qs.Common
import qs.Widgets

// Bottom-center search/command field. "/" focuses it, Esc blurs it back to
// panel mode, Enter runs the active command (see commands.js) then hands
// focus back to panel mode too.
StyledRect {
    id: root

    property alias text: field.text
    property alias field: field

    // DankTextField's own root is a plain Rectangle, not a FocusScope, so
    // `field.activeFocus` never reflects the inner TextInput's real focus —
    // it stays false even while the field visibly has the cursor. This
    // mirrors it via DankTextField's own forwarding signal instead.
    property bool hasFocus: false

    signal textEdited
    signal accepted

    width: 520
    height: 48
    radius: Theme.cornerRadius * 1.5
    color: Theme.floatingWindowSurface
    border.color: Theme.outlineMedium
    border.width: Theme.layerOutlineWidth

    DankTextField {
        id: field

        anchors.fill: parent
        anchors.margins: 2
        placeholderText: "/ to search — try \"wifi home\", Enter connects"
        leftIconName: "search"
        showClearButton: true
        cornerRadius: root.radius - 2
        onTextEdited: root.textEdited()
        onAccepted: root.accepted()
        onFocusStateChanged: focused => root.hasFocus = focused
    }
}
