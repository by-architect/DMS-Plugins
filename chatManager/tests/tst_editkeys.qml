import QtQuick
import QtTest
import ".."

// Ctrl+W and Ctrl+U in every text field (EditKeys.qml), pressed for real.
//
// The shell's DankTextField cannot load outside the shell, so FakeField below
// has its shape -- DCommon/Widgets/DTextField.qml: a Rectangle around a
// TextInput that hands its keys to keyForwardTargets first, the field's own
// functions over it, and a hidden input that echoes and keeps nothing, which
// holds the keyboard of a masked password and types into the real one.
Item {
    id: window

    width: 400
    height: 300

    component FakeField: Rectangle {
        id: f

        property alias text: input.text
        property alias cursorPosition: input.cursorPosition
        property alias readOnly: input.readOnly
        property var keyForwardTargets: []
        property bool password: false
        readonly property alias input: input

        width: 300
        height: 30

        function select(start, end) {
            input.select(start, end);
        }
        function backspace() {
            if (input.selectedText.length > 0) {
                input.remove(input.selectionStart, input.selectionEnd);
                return;
            }
            if (input.cursorPosition > 0)
                input.remove(input.cursorPosition - 1, input.cursorPosition);
        }
        function clear() {
            input.clear();
        }
        function focusIt() {
            (f.password ? sink : input).forceActiveFocus();
        }

        TextInput {
            id: sink

            width: 1
            height: 10
            opacity: 0
            echoMode: TextInput.NoEcho
            Keys.forwardTo: [input]
        }

        TextInput {
            id: input

            anchors.fill: parent
            echoMode: f.password ? TextInput.Password : TextInput.Normal
            Keys.forwardTo: f.keyForwardTargets
        }
    }

    property int others: 0

    Column {
        id: inside

        width: parent.width

        FakeField {
            id: field
        }

        FakeField {
            id: secret

            password: true
        }

        // A field with a forward target of its own already: it keeps it.
        FakeField {
            id: busy

            keyForwardTargets: [otherKeys]
        }

        // Ours: a TextEdit, handed the keys by hand.
        TextEdit {
            id: edit

            width: 300
            height: 60
            textFormat: TextEdit.PlainText
            Keys.forwardTo: [editKeys]
            Keys.onShortcutOverride: event => event.accepted = editKeys.claims(event)
        }

        EditKeys {
            id: editKeys
        }
    }

    // A settings page puts every item it is given in a column like this one:
    // this takes no room there.
    Column {
        id: page

        y: 200
        spacing: 10

        Rectangle {
            width: 10
            height: 20
        }

        EditKeys {}

        Rectangle {
            id: below

            width: 10
            height: 20
        }
    }

    // Someone else's field, in the same window: not ours to change.
    FakeField {
        id: outside

        y: 250
    }

    Item {
        id: otherKeys

        Keys.onPressed: event => {
            if (event.key === Qt.Key_K) {
                window.others++;
                event.accepted = true;
            }
        }
    }

    TestCase {
        name: "EditKeys"
        when: windowShown

        function ctrl(key) {
            keyClick(key, Qt.ControlModifier);
        }

        function type(target, text, cursor) {
            target.text = text;
            target.cursorPosition = cursor === undefined ? text.length : cursor;
        }

        function init() {
            field.focusIt();
            verify(field.input.activeFocus);
            compare(editKeys.focusedItem, field.input, "Window.activeFocusItem reaches here");
        }

        function test_ctrl_w_takes_the_word_before_the_cursor() {
            type(field, "hello big world");
            ctrl(Qt.Key_W);
            compare(field.text, "hello big ");
            ctrl(Qt.Key_W);
            compare(field.text, "hello ");
            ctrl(Qt.Key_W);
            compare(field.text, "");
            ctrl(Qt.Key_W);
            compare(field.text, "", "and at the start, nothing");
        }

        function test_ctrl_w_goes_back_over_spaces_first() {
            type(field, "hello world   ");
            ctrl(Qt.Key_W);
            compare(field.text, "hello ");
        }

        function test_ctrl_w_in_the_middle() {
            type(field, "one two three", 7);
            ctrl(Qt.Key_W);
            compare(field.text, "one  three");
            compare(field.cursorPosition, 4);
        }

        function test_a_path_is_one_word() {
            type(field, "open ~/Projects/foo.txt");
            ctrl(Qt.Key_W);
            compare(field.text, "open ");
        }

        function test_a_selection_goes_instead() {
            type(field, "hello world");
            field.select(0, 5);
            ctrl(Qt.Key_W);
            compare(field.text, " world");
        }

        function test_ctrl_u_clears_everything() {
            type(field, "hello world", 5);
            ctrl(Qt.Key_U);
            compare(field.text, "", "not only up to the cursor");
        }

        function test_ctrl_z_puts_it_back() {
            type(field, "x");
            type(field, "");
            keyClick(Qt.Key_A);
            keyClick(Qt.Key_Space);
            keyClick(Qt.Key_B);
            compare(field.text, "a b");
            ctrl(Qt.Key_W);
            compare(field.text, "a ");
            ctrl(Qt.Key_Z);
            compare(field.text, "a b");
            ctrl(Qt.Key_U);
            compare(field.text, "");
            ctrl(Qt.Key_Z);
            compare(field.text, "a b");
        }

        function test_ctrl_z_puts_it_back_in_a_text_edit_too() {
            edit.forceActiveFocus();
            type(edit, "");
            keyClick(Qt.Key_A);
            keyClick(Qt.Key_Space);
            keyClick(Qt.Key_B);
            ctrl(Qt.Key_W);
            compare(edit.text, "a ");
            ctrl(Qt.Key_Z);
            compare(edit.text, "a b");
        }

        function test_other_chords_pass() {
            type(field, "hello world");
            keyClick(Qt.Key_W, Qt.ControlModifier | Qt.ShiftModifier);
            compare(field.text, "hello world", "Ctrl+Shift+W is not Ctrl+W");
            keyClick(Qt.Key_W);
            compare(field.text, "hello worldw", "and W alone types");
        }

        function test_a_field_keeps_its_own_forward_targets() {
            busy.focusIt();
            type(busy, "one two");
            compare(busy.keyForwardTargets.length, 2);
            compare(busy.keyForwardTargets[0], editKeys, "ours first");
            window.others = 0;
            ctrl(Qt.Key_K);
            compare(window.others, 1, "its own still hear the rest");
            ctrl(Qt.Key_W);
            compare(busy.text, "one ");
        }

        function test_a_text_edit_handed_the_keys() {
            edit.forceActiveFocus();
            type(edit, "line one\nline two");
            ctrl(Qt.Key_W);
            compare(edit.text, "line one\nline ");
            ctrl(Qt.Key_W);
            ctrl(Qt.Key_W);
            compare(edit.text, "line ", "a line break is a space");
            type(edit, "line one\nline two", 3);
            ctrl(Qt.Key_U);
            compare(edit.text, "");
        }

        function test_a_password_word_is_everything_before_the_cursor() {
            secret.focusIt();
            compare(editKeys.focusedItem.echoMode, TextInput.NoEcho, "the hidden input has the keyboard");
            type(secret, "two words");
            ctrl(Qt.Key_W);
            compare(secret.text, "", "its spaces cannot be seen");
            type(secret, "abc", 1);
            ctrl(Qt.Key_W);
            compare(secret.text, "bc");
            ctrl(Qt.Key_U);
            compare(secret.text, "");
        }

        function test_read_only_is_left_alone() {
            type(field, "hello world");
            field.readOnly = true;
            ctrl(Qt.Key_W);
            ctrl(Qt.Key_U);
            compare(field.text, "hello world");
            field.readOnly = false;
        }

        function test_fields_outside_the_scope_are_not_ours() {
            outside.focusIt();
            type(outside, "hello world");
            ctrl(Qt.Key_W);
            compare(outside.keyForwardTargets.length, 0, "not adopted");
            compare(outside.text, "hello world");
        }

        function test_it_takes_no_room_on_a_page() {
            compare(below.y, 30, "no gap where it is");
        }

        function test_word_start() {
            compare(editKeys.wordStart("abc def", 7), 4);
            compare(editKeys.wordStart("abc def", 4), 0);
            compare(editKeys.wordStart("abc\tdef", 7), 4);
            compare(editKeys.wordStart("", 0), 0);
            compare(editKeys.wordStart("abc", 99), 0, "a cursor past the end is the end");
        }
    }
}
