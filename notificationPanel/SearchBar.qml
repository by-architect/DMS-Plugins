import QtQuick
import qs.Common
import qs.Widgets

// Bottom-center floating search field. Its text is ANDed into every category
// filter and the main flow.
StyledRect {
    id: root

    property alias text: field.text
    property alias field: field

    signal textEdited

    width: 480
    height: 48
    radius: Theme.cornerRadius * 1.5
    color: Theme.floatingWindowSurface
    border.color: Theme.outlineMedium
    border.width: Theme.layerOutlineWidth

    DankTextField {
        id: field

        anchors.fill: parent
        anchors.margins: 2
        placeholderText: "Search all notifications… try title:whatsapp"
        leftIconName: "search"
        showClearButton: true
        cornerRadius: root.radius - 2
        onTextEdited: root.textEdited()
    }
}
