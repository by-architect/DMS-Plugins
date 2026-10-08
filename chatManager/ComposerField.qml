import QtQuick
import qs.DankCommon.Common
import qs.Widgets

// The composer's text field: one line until there is more to say.
//
// The composer used DankTextField, which is a single-line TextInput: a newline
// could not be typed, and a block of code pasted in arrived as one long line --
// so the Markdown the window now renders, code blocks and lists above all,
// could not be written. DankTextEdit is multi-line, but a fixed, notes-sized
// box with its editor out of reach, so Return could not be told apart from
// Shift+Return there. This is DankTextField's look over a TextEdit that grows a
// line at a time, up to maxLines, and scrolls after that.
//
// Keys, which tests/tst_keys.qml pins down:
//   Return        submitted() -- the composer sends
//   Shift+Return  a new line, inserted as "\n" (TextEdit's own inserts U+2028,
//                 which no chat service treats as a line break)
//   Ctrl+Return   not ours: the conversation opens the selected message with it
StyledRect {
    id: root

    property alias text: edit.text
    property alias cursorPosition: edit.cursorPosition
    property string placeholderText: ""
    property var keyForwardTargets: []
    property int maxLines: 8

    readonly property bool placeholderVisible: edit.text.length === 0 && !edit.inputMethodComposing && !edit.activeFocus

    signal focusStateChanged(bool hasFocus)
    signal submitted

    function forceActiveFocus() {
        edit.forceActiveFocus();
    }

    function getActiveFocus() {
        return edit.activeFocus;
    }

    function _onReturn(event) {
        if (event.modifiers & Qt.ShiftModifier) {
            if (edit.selectedText !== "")
                edit.remove(edit.selectionStart, edit.selectionEnd);
            edit.insert(edit.cursorPosition, "\n");
            event.accepted = true;
            return;
        }
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
            event.accepted = false;
            return;
        }
        root.submitted();
        event.accepted = true;
    }

    // The editor's own line pitch, so the cap falls between two lines rather
    // than through one.
    readonly property real _lineHeight: edit.lineCount > 0 ? edit.contentHeight / edit.lineCount : metrics.height

    width: Style.fieldDefaultWidth
    implicitHeight: Math.max(Style.fieldHeight, Math.min(edit.contentHeight, root._lineHeight * root.maxLines) + Style.spacingS * 2)
    height: implicitHeight
    radius: Style.cornerRadiusXS
    color: Style.foregroundColor(Style.chipSurface, !Style.isFloatingWindow(root))
    border.color: edit.activeFocus ? Style.primary : Style.outlineVariant
    border.width: edit.activeFocus ? Style.outlineWidthFocused : Style.outlineWidth

    FontMetrics {
        id: metrics
        font: edit.font
    }

    DankFlickable {
        id: scroll

        function ensureCursorVisible() {
            if (height <= 0)
                return;
            const r = edit.cursorRectangle;
            if (r.y < contentY)
                contentY = r.y;
            else if (r.y + r.height > contentY + height)
                contentY = r.y + r.height - height;
        }

        anchors.fill: parent
        anchors.leftMargin: Style.spacingM
        anchors.rightMargin: Style.spacingM
        anchors.topMargin: Style.spacingS
        anchors.bottomMargin: Style.spacingS
        clip: true
        contentWidth: width
        contentHeight: edit.height
        interactive: edit.contentHeight > height

        TextEdit {
            id: edit

            width: scroll.width
            height: Math.max(scroll.height, contentHeight)
            verticalAlignment: TextEdit.AlignVCenter
            activeFocusOnTab: root.enabled
            Accessible.name: root.placeholderText
            font.pixelSize: Style.fontSizeMedium
            font.family: Style.fontFamily
            font.weight: Style.fontWeight
            color: Style.surfaceText
            selectionColor: Style.selectedContainer
            selectedTextColor: Style.onSelectedContainer
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            selectByMouse: true
            cursorDelegate: DankTextCursor {
                color: edit.color
                x: edit.cursorRectangle.x
                y: edit.cursorRectangle.y
                height: edit.cursorRectangle.height
                shown: edit.cursorVisible

                readonly property int editCursorPosition: edit.cursorPosition
                readonly property string editText: edit.text

                onEditCursorPositionChanged: resetBlink()
                onEditTextChanged: resetBlink()
            }

            Keys.forwardTo: root.keyForwardTargets
            Keys.onReturnPressed: event => root._onReturn(event)
            Keys.onEnterPressed: event => root._onReturn(event)

            onActiveFocusChanged: root.focusStateChanged(activeFocus)
            onCursorRectangleChanged: scroll.ensureCursorVisible()

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.IBeamCursor
                acceptedButtons: Qt.NoButton
            }
        }
    }

    StyledText {
        anchors.fill: scroll
        verticalAlignment: Text.AlignVCenter
        text: root.placeholderText
        font: edit.font
        color: Style.onSurfaceVariant
        elide: Text.ElideRight
        visible: root.placeholderVisible
    }
}
