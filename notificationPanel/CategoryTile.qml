import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "filters.js" as Filters

// One of the six category slots. Empty shows an "add" placeholder; filled
// shows a header (name, match count, edit/delete) plus a filtered flow.
// Editing happens inline, in place, rather than as a separate dialog.
Rectangle {
    id: root

    // null when this slot is empty.
    property var category: null
    required property var allItems
    required property string searchQuery

    signal saveRequested(var category)
    signal deleteRequested

    property bool editing: false
    property var editConditions: []

    readonly property var searchTokens: Filters.parseFilter(searchQuery)
    readonly property var matched: {
        if (!category)
            return [];
        return allItems.filter(it => Filters.matchesConditions(it, category.conditions) && Filters.matches(it, searchTokens));
    }
    // Live preview while editing, ignoring rows whose text is still empty.
    readonly property var previewConditions: editConditions.filter(c => (c.value || "").trim().length > 0)
    readonly property var previewMatched: allItems.filter(it => Filters.matchesConditions(it, previewConditions))

    radius: Theme.cornerRadius
    color: Theme.floatingWindowNestedSurface
    border.color: editing ? Theme.primary : Theme.outlineMedium
    border.width: editing ? 2 : Theme.layerOutlineWidth
    clip: true

    function blankCondition() {
        return {
            field: "any",
            mode: "include",
            value: ""
        };
    }

    function startEdit() {
        nameField.text = category ? category.name : "";
        const existing = category ? category.conditions : null;
        editConditions = existing && existing.length ? existing.map(c => Object.assign({}, c)) : [blankCondition()];
        editing = true;
    }

    function cancelEdit() {
        editing = false;
    }

    function addCondition() {
        editConditions = editConditions.concat([blankCondition()]);
    }

    function updateCondition(index, next) {
        const arr = editConditions.slice();
        arr[index] = next;
        editConditions = arr;
    }

    function removeCondition(index) {
        const arr = editConditions.slice();
        arr.splice(index, 1);
        editConditions = arr;
    }

    function commitEdit() {
        const name = nameField.text.trim();
        const conditions = previewConditions;
        if (!name || conditions.length === 0)
            return;
        root.saveRequested({
            name: name,
            conditions: conditions
        });
        editing = false;
    }

    // -------------------------------------------------------------- empty
    Column {
        anchors.centerIn: parent
        spacing: Theme.spacingS
        visible: root.category === null && !root.editing

        DankIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "add_circle_outline"
            size: 26
            color: Theme.surfaceVariantText
        }

        StyledText {
            text: "Add category"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    MouseArea {
        anchors.fill: parent
        visible: root.category === null && !root.editing
        onClicked: root.startEdit()
    }

    // ------------------------------------------------------------- editor
    // The whole form scrolls as one unit — simpler than carving out a fixed
    // header/footer around a scrollable middle, and it still works no matter
    // how many condition rows get added.
    DankFlickable {
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        clip: true
        contentHeight: editorCol.height
        contentWidth: width
        visible: root.editing

        Column {
            id: editorCol

            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                text: root.category ? "Edit category" : "New category"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            DankTextField {
                id: nameField

                width: parent.width
                placeholderText: "Name (e.g. WhatsApp)"
            }

            StyledText {
                text: "Conditions (all must match)"
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: root.editConditions

                FilterCondition {
                    required property int index
                    required property var modelData

                    width: editorCol.width
                    condition: modelData
                    removable: root.editConditions.length > 1
                    onChanged: next => root.updateCondition(index, next)
                    onRemoveRequested: root.removeCondition(index)
                }
            }

            DankButton {
                text: "Add condition"
                iconName: "add"
                onClicked: root.addCondition()
            }

            StyledText {
                width: parent.width
                text: root.previewMatched.length + " match" + (root.previewMatched.length === 1 ? "" : "es") + " right now"
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankButton {
                    text: "Save"
                    enabled: nameField.text.trim().length > 0 && root.previewConditions.length > 0
                    onClicked: root.commitEdit()
                }

                DankButton {
                    text: "Cancel"
                    onClicked: root.cancelEdit()
                }

                DankActionButton {
                    iconName: "delete"
                    iconSize: 18
                    visible: root.category !== null
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.deleteRequested()
                }
            }
        }
    }

    // -------------------------------------------------------------- filled
    Column {
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingS
        visible: root.category !== null && !root.editing

        Item {
            width: parent.width
            height: 22

            DankIcon {
                id: catIcon

                name: "filter_alt"
                size: 16
                color: Theme.primary
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                anchors.left: catIcon.right
                anchors.leftMargin: Theme.spacingXS
                anchors.right: catButtons.left
                anchors.rightMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                text: root.category ? root.category.name : ""
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            Row {
                id: catButtons

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    text: root.matched.length
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankActionButton {
                    iconName: "edit"
                    iconSize: 14
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.startEdit()
                }

                DankActionButton {
                    iconName: "delete"
                    iconSize: 14
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.deleteRequested()
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.outlineVariant
            opacity: 0.5
        }

        Item {
            width: parent.width
            height: parent.height - 22 - 1 - Theme.spacingS * 2

            DankFlickable {
                anchors.fill: parent
                clip: true
                contentHeight: catCol.height
                contentWidth: width
                visible: root.matched.length > 0

                Column {
                    id: catCol

                    width: parent.width
                    spacing: 1

                    Repeater {
                        model: root.matched

                        NotificationRow {
                            required property var modelData

                            item: modelData
                            onRemoveRequested: NotificationService.removeFromHistory(modelData.id)
                        }
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                width: parent.width - Theme.spacingM * 2
                horizontalAlignment: Text.AlignHCenter
                text: root.searchQuery ? "no matches for this search" : "no matches yet"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                visible: root.matched.length === 0
            }
        }
    }
}
