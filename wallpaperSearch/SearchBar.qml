import QtQuick
import qs.Common
import qs.Widgets

// Bottom-center search field, shared by both tabs. Enter runs the search
// (Wallhaven: an API call; Local: applies the filter) and hands focus back to
// the panel so Ctrl+hjkl navigation works immediately.
StyledRect {
    id: root

    property alias text: field.text
    property alias field: field

    // DankTextField's own root is a plain Rectangle, not a FocusScope, so
    // `field.activeFocus` never reflects the inner TextInput's real focus.
    // This mirrors it via DankTextField's own forwarding signal instead.
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
        placeholderText: "/ to search — Enter to fetch, Ctrl+hjkl to navigate"
        leftIconName: "search"
        showClearButton: true
        cornerRadius: root.radius - 2
        onTextEdited: root.textEdited()
        onAccepted: root.accepted()
        onFocusStateChanged: focused => root.hasFocus = focused
    }
}
