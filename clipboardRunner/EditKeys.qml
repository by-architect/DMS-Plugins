import QtQuick

// Ctrl+W deletes the word before the cursor and Ctrl+U clears the whole field,
// in every text field here: the two keys a terminal has, and the shell's own
// lock screen. A selection goes instead of the word, the way Backspace takes
// one, and in a password field the word is everything before the cursor --
// its spaces cannot be seen. Ctrl+Z puts either back. Neither touches the
// clipboard: Qt's own Ctrl+U copies what it deletes, which clearing a field
// should not.
//
// One of these looks after every field inside `scope` -- a window, a panel, a
// settings page -- acting on whichever of them holds the keyboard:
//
//   DankTextField, and the fields the shell draws itself (a settings page's
//   StringSetting): adopted as each takes focus. This goes first in the
//   field's keyForwardTargets, which hear a key before the field acts on it,
//   so the field's own Ctrl+U never runs.
//   A TextEdit or TextInput of our own has no such list: give it this in
//   Keys.forwardTo, and claim the keys in Keys.onShortcutOverride with
//   claims(event), so no shortcut of the window's can take them first.
//
// Every plugin with a text field carries this file, word for word -- a plugin
// is installed on its own and cannot import another's. chatManager's copy is
// the one tested (tests/tst_editkeys.qml); tests/editkeys.test.js keeps the
// others the same as it.
Item {
    id: root

    // Where the fields this looks after are. The shell's settings window holds
    // every plugin's page, and the fields of the others are left alone.
    property Item scope: parent

    readonly property Item focusedItem: Window.activeFocusItem

    // Where the word before `cursor` starts: back over the spaces, then over
    // the word up to the space before it, the way a shell's Ctrl+W goes -- a
    // path or a link goes in one.
    function wordStart(text, cursor) {
        let i = Math.max(0, Math.min(cursor, text.length));
        while (i > 0 && /\s/.test(text.charAt(i - 1)))
            i--;
        while (i > 0 && !/\s/.test(text.charAt(i - 1)))
            i--;
        return i;
    }

    // Whether the key is one of the two, with Ctrl and nothing else.
    function claims(event) {
        return (event.key === Qt.Key_W || event.key === Qt.Key_U) && (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)) === Qt.ControlModifier;
    }

    // handle acts on the key for the field with the keyboard: true when it was
    // one of the two and that field is one to type in.
    function handle(event) {
        if (!root.claims(event))
            return false;
        const clear = event.key === Qt.Key_U;
        const item = root.focusedItem;
        if (!item)
            return false;
        const field = root._sinkField(item);
        if (field)
            return root._onField(field, clear);
        if (typeof item.remove !== "function" || typeof item.text !== "string" || typeof item.cursorPosition !== "number" || item.readOnly)
            return false;
        if (clear) {
            root._remove(item, 0, typeof item.length === "number" ? item.length : item.text.length);
            return true;
        }
        if (item.selectionStart !== item.selectionEnd) {
            root._remove(item, item.selectionStart, item.selectionEnd);
            return true;
        }
        const end = item.cursorPosition;
        const masked = typeof item.echoMode === "number" && item.echoMode !== TextInput.Normal;
        root._remove(item, masked ? 0 : root.wordStart(item.text, end), end);
        return true;
    }

    // The cursor moves first, because that is what makes Ctrl+Z take back
    // this and only this: a TextInput folds an edit into the typing before it
    // unless the cursor moved in between, and the word typed went with it.
    function _remove(item, start, end) {
        if (start >= end)
            return;
        item.cursorPosition = item.cursorPosition === start ? end : start;
        item.remove(start, end);
    }

    // DankTextField hands the keyboard of a hidden password to an input of its
    // own that echoes and keeps nothing: the text is in the field around it,
    // reached through the field's own functions.
    function _sinkField(item) {
        if (item.echoMode !== TextInput.NoEcho || item.text !== "")
            return null;
        const field = item.parent;
        if (!field || typeof field.backspace !== "function" || typeof field.select !== "function" || typeof field.clear !== "function")
            return null;
        return field;
    }

    function _onField(field, clear) {
        if (field.readOnly)
            return false;
        if (clear) {
            if (field.text !== "")
                field.clear();
            return true;
        }
        const end = field.cursorPosition;
        if (end > 0) {
            field.select(0, end);
            field.backspace();
        }
        return true;
    }

    function _inScope(item) {
        for (let p = item; p; p = p.parent) {
            if (p === root.scope)
                return true;
        }
        return false;
    }

    // A field the shell draws hears keys only through its keyForwardTargets:
    // this goes first in that list the moment the field takes focus.
    function _adopt(item) {
        if (!item || !root.scope || !root._inScope(item))
            return;
        for (let p = item.parent, up = 0; p && up < 3; p = p.parent, up++) {
            if (p.keyForwardTargets === undefined || typeof p.backspace !== "function")
                continue;
            const targets = p.keyForwardTargets || [];
            if (targets.indexOf(root) < 0)
                p.keyForwardTargets = [root].concat(targets);
            return;
        }
    }

    onFocusedItemChanged: root._adopt(root.focusedItem)
    Component.onCompleted: root._adopt(root.focusedItem)

    Keys.onPressed: event => {
        if (root.handle(event))
            event.accepted = true;
    }
}
