import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import "view.js" as View
import "sync.js" as Sync

// Everything in the window: the tasks as lines stacked upwards from the
// field at the bottom, newest nearest to it, and every key.
//
// The field keeps the keyboard the whole time, so typing always types; the
// selected task is only a highlight that Ctrl+J/K walk up and down, and
// what Ctrl+Enter and Ctrl+Delete act on. Text starting with "/" searches
// instead of being a task, and Enter then goes back to the whole list with
// what was found still selected, the way Enter ends a search in vim.
//
// An Item of its own, apart from the layer-shell window around it, so the
// tests can drive it under qmltestrunner.
Rectangle {
    id: card

    property var service: null
    signal closeRequested

    readonly property bool keyboardReady: field.activeFocus

    // ------------------------------------------------------------- state
    property string selectedUid: ""
    // Tasks marked in this sitting stay in view until it ends, even done
    // ones the settings would hide -- uid -> true.
    property var keep: ({})
    property real nowMs: Date.now()
    property string undoText: ""
    readonly property bool undoActive: undoText !== ""

    readonly property bool searching: field.text.charAt(0) === "/"
    readonly property string query: searching ? field.text.slice(1) : ""
    readonly property var rows: View.rows(service ? service.tasks : [], {
        query: searching ? query : null,
        nowMs: nowMs,
        keepDoneHours: service ? service.keepDoneHours : 24,
        keep: keep
    })
    readonly property int selectedIndex: {
        const uid = selectedUid;
        if (!uid)
            return -1;
        for (let i = 0; i < rows.length; i++) {
            if (rows[i].uid === uid)
                return i;
        }
        return -1;
    }
    readonly property int openCount: service ? service.tasks.filter(t => !t.completed).length : 0
    readonly property var syncLine: service ? View.syncLine(service.status, service.configured, nowMs) : {
        text: "",
        error: false
    }

    // Every time the window opens: a fresh sitting, the keyboard in the
    // field, the newest tasks in view. A half-typed task is a draft and
    // stays; a search does not.
    function opened() {
        nowMs = Date.now();
        keep = ({});
        selectedUid = "";
        undoText = "";
        if (searching)
            field.text = "";
        field.forceActiveFocus();
        field.cursorPosition = field.length;
        Qt.callLater(positionSelection);
    }

    // ----------------------------------------------------------- actions

    // Keeps the selected row in view, or the newest rows when none is.
    function positionSelection() {
        if (selectedUid !== "" && selectedIndex < 0)
            selectedUid = "";
        if (selectedIndex >= 0)
            list.positionViewAtIndex(selectedIndex, ListView.Contain);
        else
            list.positionViewAtBeginning();
    }

    // +1 is up (older), -1 down; down from the bottom row is the field.
    function moveSelection(delta) {
        if (rows.length === 0)
            return;
        const i = selectedIndex + delta;
        if (i < 0) {
            selectedUid = "";
            list.positionViewAtBeginning();
            return;
        }
        const j = Math.min(i, rows.length - 1);
        selectedUid = rows[j].uid;
        list.positionViewAtIndex(j, ListView.Contain);
    }

    function select(uid) {
        selectedUid = uid;
        field.forceActiveFocus();
    }

    function submit() {
        if (searching) {
            const uid = selectedUid;
            if (uid)
                keep = Object.assign({}, keep, {
                    [uid]: true
                });
            field.text = "";
            selectedUid = uid;
            Qt.callLater(positionSelection);
            return;
        }
        if (!service || field.text.trim() === "")
            return;
        if (!service.add(field.text))
            return;
        field.text = "";
        selectedUid = "";
        Qt.callLater(positionSelection);
    }

    function newLine() {
        if (field.selectedText !== "")
            field.remove(field.selectionStart, field.selectionEnd);
        const pos = field.cursorPosition;
        field.insert(pos, "\n");
        field.cursorPosition = pos + 1;
    }

    function toggle(uid) {
        const r = rows.find(x => x.uid === uid);
        if (!r || !service)
            return;
        keep = Object.assign({}, keep, {
            [uid]: true
        });
        service.setDone(uid, !r.completed);
    }

    // The selection moves to the row that takes the deleted one's place --
    // the one above it, or below when it was the top one.
    function remove(uid) {
        const i = rows.findIndex(x => x.uid === uid);
        if (i < 0 || !service)
            return;
        const r = rows[i];
        const next = rows[i + 1] || rows[i - 1] || null;
        if (!service.remove(uid))
            return;
        undoText = r.summary || "(untitled)";
        undoTimer.restart();
        if (selectedUid === uid)
            selectedUid = next ? next.uid : "";
        Qt.callLater(positionSelection);
    }

    function undo() {
        const uid = service ? service.undoRemove() : "";
        undoText = "";
        undoTimer.stop();
        if (uid) {
            selectedUid = uid;
            Qt.callLater(positionSelection);
        }
    }

    function stepBack() {
        if (searching) {
            field.text = "";
            selectedUid = "";
            positionSelection();
        } else if (selectedUid !== "") {
            selectedUid = "";
            positionSelection();
        } else {
            closeRequested();
        }
    }

    function handleKey(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        if (event.modifiers & (Qt.AltModifier | Qt.MetaModifier))
            return;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (ctrl) {
                if (selectedIndex >= 0)
                    toggle(selectedUid);
            } else if (shift) {
                newLine();
            } else {
                submit();
            }
            event.accepted = true;
            return;
        }
        if (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_K)) {
            moveSelection(event.key === Qt.Key_K ? 1 : -1);
            event.accepted = true;
            return;
        }
        // With no task selected, Ctrl+Delete is the field's own: delete
        // the next word.
        if (ctrl && event.key === Qt.Key_Delete && selectedIndex >= 0) {
            remove(selectedUid);
            event.accepted = true;
            return;
        }
        // Only while "Ctrl+Z brings it back" is showing; otherwise it is the
        // field's own undo.
        if (ctrl && !shift && event.key === Qt.Key_Z && undoActive) {
            undo();
            event.accepted = true;
            return;
        }
        if (ctrl && event.key === Qt.Key_R) {
            if (service)
                service.syncNow();
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Escape) {
            stepBack();
            event.accepted = true;
            return;
        }
        // Arrows walk the list too, but only when there is no text in the
        // field for them to move through.
        if (!ctrl && field.text === "" && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
            moveSelection(event.key === Qt.Key_Up ? 1 : -1);
            event.accepted = true;
        }
    }

    // Every edit of a search picks its best match at once, so Ctrl+Enter or
    // Ctrl+Delete act on it without walking there first. Worked out from the
    // field's text itself rather than from `rows`: inside a change handler,
    // `rows` may not have caught up with the edit yet -- pasting "/milk" into
    // an empty field changes the search and its words in one go.
    function searchEdited() {
        const text = field.text;
        if (text.charAt(0) !== "/")
            return;
        const found = View.rows(service ? service.tasks : [], {
            query: text.slice(1),
            nowMs: nowMs,
            keepDoneHours: service ? service.keepDoneHours : 24,
            keep: keep
        });
        selectedUid = found.length > 0 ? found[0].uid : "";
        Qt.callLater(positionSelection);
    }

    // The list's model is the row count, so a task changing in place --
    // marked done, synced -- keeps the scroll where it was; only a row
    // coming or going rebuilds it, and then the selection is found again.
    property int _rowCount: 0

    onRowsChanged: {
        if (rows.length === _rowCount)
            return;
        _rowCount = rows.length;
        Qt.callLater(positionSelection);
    }

    Timer {
        interval: 30000
        repeat: true
        running: card.visible
        onTriggered: card.nowMs = Date.now()
    }

    Timer {
        id: undoTimer

        interval: Sync.UNDO_MS
        onTriggered: card.undoText = ""
    }

    radius: Theme.cornerRadius * 1.5
    color: Theme.surfaceContainer
    border.color: Theme.outline
    border.width: 1

    // A click anywhere on the card is not a click outside it, and gives the
    // keyboard back to the field.
    MouseArea {
        anchors.fill: parent
        onClicked: field.forceActiveFocus()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingM

        // -------------------------------------------------------- header
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            DankIcon {
                name: "edit_note"
                size: 26
                color: Theme.primary
                Layout.alignment: Qt.AlignVCenter
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Row {
                    spacing: Theme.spacingS

                    StyledText {
                        text: "Quick Notes"
                        font.pixelSize: Theme.fontSizeLarge + 2
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        height: listChip.implicitHeight + 4
                        width: listChip.implicitWidth + Theme.spacingS * 2
                        radius: height / 2
                        color: Theme.surfaceContainerHigh

                        StyledText {
                            id: listChip

                            anchors.centerIn: parent
                            text: (card.service ? card.service.listTitle : "main") + " · " + card.openCount + " open"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    text: card.undoActive ? "Deleted “" + card.undoText + "” — Ctrl+Z brings it back" : card.syncLine.text
                    color: !card.undoActive && card.syncLine.error ? Theme.error : Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    elide: Text.ElideRight
                }
            }

            DankSpinner {
                visible: card.service ? card.service.syncing : false
                running: visible
                size: 16
                Layout.alignment: Qt.AlignVCenter
            }

            DankActionButton {
                iconName: "sync"
                iconSize: 18
                Layout.alignment: Qt.AlignVCenter
                onClicked: {
                    if (card.service)
                        card.service.syncNow();
                    field.forceActiveFocus();
                }
            }

            DankActionButton {
                iconName: "close"
                iconSize: 20
                Layout.alignment: Qt.AlignVCenter
                onClicked: card.closeRequested()
            }
        }

        // --------------------------------------------------------- tasks
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: list

                objectName: "taskList"
                anchors.fill: parent
                clip: true
                verticalLayoutDirection: ListView.BottomToTop
                spacing: 2
                boundsBehavior: Flickable.StopAtBounds
                keyNavigationEnabled: false
                model: card.rows.length

                delegate: TaskRow {
                    required property int index

                    width: list.width
                    task: card.rows[index] || null
                    selected: index === card.selectedIndex
                    nowMs: card.nowMs
                    onSelectRequested: card.select(task.uid)
                    onToggleRequested: {
                        card.select(task.uid);
                        card.toggle(task.uid);
                    }
                    // DMS buttons take the keyboard when clicked; it goes
                    // straight back to the field.
                    onDeleteRequested: {
                        card.remove(task.uid);
                        field.forceActiveFocus();
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                width: parent.width - Theme.spacingL * 2
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: card.rows.length === 0
                text: card.searching ? (card.query.trim() ? "Nothing matches “" + card.query.trim() + "”" : "Type to search every task, done ones too") : "Nothing to do. Type a task below and press Enter."
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeMedium
            }
        }

        // --------------------------------------------------------- field
        Rectangle {
            id: inputBox

            readonly property real lineHeight: Math.ceil(field.font.pixelSize * 1.4)

            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(Math.max(field.contentHeight, lineHeight), lineHeight * 6) + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh
            border.color: field.activeFocus ? Theme.primary : Theme.outlineMedium
            border.width: field.activeFocus ? 2 : 1

            DankIcon {
                id: fieldIcon

                name: card.searching ? "search" : "add"
                size: 20
                color: card.searching ? Theme.primary : Theme.surfaceVariantText
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingM
                anchors.top: parent.top
                anchors.topMargin: Theme.spacingM + (inputBox.lineHeight - size) / 2
            }

            StyledText {
                id: matchCount

                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingM
                anchors.top: parent.top
                anchors.topMargin: Theme.spacingM + (inputBox.lineHeight - implicitHeight) / 2
                visible: card.searching
                width: visible ? implicitWidth : 0
                text: card.rows.length + (card.rows.length === 1 ? " match" : " matches")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Flickable {
                id: fieldFlick

                // Keeps the cursor in sight once the text is taller than
                // the box.
                function follow(r) {
                    if (contentY >= r.y)
                        contentY = r.y;
                    else if (contentY + height <= r.y + r.height)
                        contentY = r.y + r.height - height;
                }

                anchors.left: fieldIcon.right
                anchors.leftMargin: Theme.spacingS
                anchors.right: matchCount.left
                anchors.rightMargin: matchCount.visible ? Theme.spacingS : 0
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: Theme.spacingM
                anchors.bottomMargin: Theme.spacingM
                contentWidth: width
                contentHeight: field.contentHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                TextEdit {
                    id: field

                    objectName: "field"
                    width: fieldFlick.width
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    font.pixelSize: Theme.fontSizeMedium
                    font.family: Theme.fontFamily
                    color: Theme.surfaceText
                    selectionColor: Theme.withAlpha(Theme.primary, 0.35)
                    selectedTextColor: Theme.surfaceText
                    selectByMouse: true
                    focus: true
                    onCursorRectangleChanged: fieldFlick.follow(cursorRectangle)
                    onTextChanged: card.searchEdited()
                    Keys.onPressed: event => card.handleKey(event)
                }
            }

            StyledText {
                anchors.left: fieldFlick.left
                anchors.right: fieldFlick.right
                anchors.top: fieldFlick.top
                visible: field.text === "" && !field.preeditText
                text: "A new task — Enter saves it, / searches"
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }

        StyledText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: "Enter save · Shift+Enter new line · Ctrl+J/K move · Ctrl+Enter done · Ctrl+Del delete · / search · Ctrl+R sync · Esc close"
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            opacity: 0.8
            elide: Text.ElideRight
        }
    }
}
