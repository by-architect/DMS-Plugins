import QtQuick
import QtTest

// Why the chat window's keys are the keys they are.
//
// The composer holds focus the whole time a conversation is open, so every
// shortcut has to be a chord an editable text field does not want for itself.
// A field answers for those before the shortcut system is ever asked, and a
// shortcut it answers for simply never fires -- silently, which is how Ctrl+V
// came to do nothing at all for images and how Delete never reached a message.
//
// Worse, a field claims some chords only *sometimes*: Ctrl+U is taken when
// there is text before the cursor to delete and free when there is not. A key
// that works until you have typed something is the hardest kind of bug to
// report, so the keymap is checked here against every state a half-written
// message can be in rather than against an empty field.
Item {
    id: window

    width: 300
    height: 200

    property string lastFired: ""
    property int sends: 0

    // Everything the conversation binds while a message can be written. All of
    // these must arrive, in every state, without touching what is being typed.
    readonly property var keymap: ["Ctrl+K", "Ctrl+J", "Ctrl+R", "Ctrl+F", "Ctrl+Shift+C", "Ctrl+Return", "Ctrl+Delete", "Ctrl+Shift+Delete"]

    // The two answers to an invitation. An invitation has no composer -- the
    // field is hidden, and the keyboard with it -- so these never compete with
    // a text field, and are checked the way they are used: with nothing being
    // typed. They must stay invitation-only, too. Under some keyboard schemes
    // Ctrl+Y is Redo, which a focused field claims before any shortcut is asked
    // -- the Windows scheme does, and it is the one this test platform uses,
    // which is how this suite came to fail on a key that works.
    readonly property var inviteKeys: ["Ctrl+Y", "Ctrl+N"]

    // What the field keeps for itself, whatever the window would like. Bound
    // here so the test shows it rather than assuming it: this is the reason
    // paste is forwarded to the composer and deleting a message is Ctrl+Delete.
    readonly property var fieldKeeps: ["Ctrl+V", "Delete"]

    readonly property var chords: ({
            "Ctrl+K": [Qt.Key_K, Qt.ControlModifier],
            "Ctrl+J": [Qt.Key_J, Qt.ControlModifier],
            "Ctrl+R": [Qt.Key_R, Qt.ControlModifier],
            "Ctrl+F": [Qt.Key_F, Qt.ControlModifier],
            "Ctrl+Y": [Qt.Key_Y, Qt.ControlModifier],
            "Ctrl+N": [Qt.Key_N, Qt.ControlModifier],
            "Ctrl+Shift+C": [Qt.Key_C, Qt.ControlModifier | Qt.ShiftModifier],
            "Ctrl+Return": [Qt.Key_Return, Qt.ControlModifier],
            "Ctrl+Delete": [Qt.Key_Delete, Qt.ControlModifier],
            "Ctrl+Shift+Delete": [Qt.Key_Delete, Qt.ControlModifier | Qt.ShiftModifier],
            "Ctrl+V": [Qt.Key_V, Qt.ControlModifier],
            "Delete": [Qt.Key_Delete, Qt.NoModifier]
        })

    Repeater {
        model: window.keymap.concat(window.inviteKeys).concat(window.fieldKeeps)

        delegate: Item {
            id: binding

            required property string modelData

            Shortcut {
                sequences: [binding.modelData]
                onActivated: window.lastFired = binding.modelData
            }
        }
    }

    // Composer.qml hands Ctrl+V to an item like this one, because a text field
    // gives its forward targets a modified key before acting on it -- the one
    // place that comes before a field's own paste.
    Item {
        id: pasteKeys

        property int pastes: 0

        Keys.onPressed: event => {
            if (event.key !== Qt.Key_V || !(event.modifiers & Qt.ControlModifier))
                return;
            pasteKeys.pastes++;
            event.accepted = true;
        }
    }

    // ComposerField's shape: a multi-line TextEdit with the composer's keys
    // handled on the field itself, before it acts on them -- a TextEdit would
    // otherwise take Return for a new line. The handler is ComposerField's
    // _onReturn, word for word.
    Item {
        id: composer

        anchors.fill: parent

        function onReturn(event) {
            if (event.modifiers & Qt.ShiftModifier) {
                if (field.selectedText !== "")
                    field.remove(field.selectionStart, field.selectionEnd);
                field.insert(field.cursorPosition, "\n");
                event.accepted = true;
                return;
            }
            if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
                event.accepted = false;
                return;
            }
            window.sends++;
            event.accepted = true;
        }

        TextEdit {
            id: field

            anchors.fill: parent
            textFormat: TextEdit.PlainText
            Keys.forwardTo: [pasteKeys]
            Keys.onReturnPressed: event => composer.onReturn(event)
            Keys.onEnterPressed: event => composer.onReturn(event)
        }
    }

    TestCase {
        name: "ChatKeys"
        when: windowShown

        function init() {
            field.forceActiveFocus();
            verify(field.activeFocus);
        }

        // Every state a composer is in when somebody reaches for a shortcut.
        function drafts() {
            return [
                {
                    "name": "empty",
                    "setup": () => {
                        field.text = "";
                    }
                },
                {
                    "name": "half typed, cursor in the middle",
                    "setup": () => {
                        field.text = "hello world";
                        field.cursorPosition = 5;
                        field.deselect();
                    }
                },
                {
                    "name": "typed, cursor at the end",
                    "setup": () => {
                        field.text = "hello world";
                        field.cursorPosition = field.text.length;
                        field.deselect();
                    }
                },
                {
                    "name": "everything selected",
                    "setup": () => {
                        field.text = "hello world";
                        field.selectAll();
                    }
                },
                {
                    "name": "two lines, cursor at the end of the first",
                    "setup": () => {
                        field.text = "hello\nworld";
                        field.cursorPosition = 5;
                        field.deselect();
                    }
                },
                {
                    "name": "something to redo",
                    "setup": () => {
                        field.text = "";
                        keyClick(Qt.Key_A);
                        keyClick(Qt.Key_B);
                        keyClick(Qt.Key_Z, Qt.ControlModifier);
                    }
                }
            ];
        }

        function press(name) {
            window.lastFired = "";
            const before = field.text;
            keyClick(window.chords[name][0], window.chords[name][1]);
            return {
                "fired": window.lastFired === name,
                "edited": field.text !== before
            };
        }

        function test_the_keymap_arrives_whatever_is_being_typed() {
            const states = drafts();
            for (let s = 0; s < states.length; s++) {
                for (let k = 0; k < window.keymap.length; k++) {
                    const chord = window.keymap[k];
                    states[s].setup();

                    const result = press(chord);
                    verify(result.fired, chord + " never arrived while " + states[s].name);
                    verify(!result.edited, chord + " changed the message being written while " + states[s].name);
                }
            }
        }

        function test_the_field_keeps_paste_and_delete_whatever_we_bind() {
            const states = drafts();
            for (let s = 0; s < states.length; s++) {
                for (let k = 0; k < window.fieldKeeps.length; k++) {
                    const chord = window.fieldKeeps[k];
                    states[s].setup();

                    verify(!press(chord).fired, chord + " reached a shortcut while " + states[s].name + ", which the window does not rely on");
                }
            }
        }

        // On an invitation the composer is gone, and the answers arrive.
        //
        // Gone takes two steps, and the test shows why: a hidden field keeps
        // the keyboard in Qt Quick, so hiding the composer alone leaves every
        // key going into a box nobody can see. ConversationView releases it
        // as an invitation appears, which is the second step here.
        function test_invitation_answers_arrive_without_a_composer() {
            composer.visible = false;
            verify(field.activeFocus, "Qt now takes the keyboard from a hidden field; ConversationView's release is no longer needed");

            field.focus = false;
            verify(!field.activeFocus);

            for (let k = 0; k < window.inviteKeys.length; k++) {
                const chord = window.inviteKeys[k];
                window.lastFired = "";
                keyClick(window.chords[chord][0], window.chords[chord][1]);
                compare(window.lastFired, chord, chord + " never arrived on an invitation");
            }

            composer.visible = true;
        }

        // Which is why the composer is handed the key instead.
        function test_paste_reaches_the_composer() {
            field.text = "";
            const before = pasteKeys.pastes;
            keyClick(Qt.Key_V, Qt.ControlModifier);
            compare(pasteKeys.pastes, before + 1, "Ctrl+V should reach the composer's forward target");
        }

        // Enter sends; Shift+Enter is a new line; Ctrl+Enter is the
        // conversation's, and must neither send nor break the line.
        function test_enter_sends_and_the_chords_do_not() {
            field.text = "hello";
            field.cursorPosition = field.text.length;
            window.sends = 0;

            keyClick(Qt.Key_Return, Qt.ControlModifier);
            compare(window.sends, 0, "Ctrl+Enter opens the selected message, it does not send");
            compare(field.text, "hello", "Ctrl+Enter must not start a new line either");

            keyClick(Qt.Key_Return, Qt.ShiftModifier);
            compare(window.sends, 0, "Shift+Enter is the chord people press for a new line, not to send");
            compare(field.text, "hello\n", "Shift+Enter starts a new line, as a plain \\n");

            keyClick(Qt.Key_W);
            compare(field.text, "hello\nw", "typing carries on on the new line");

            keyClick(Qt.Key_Return);
            compare(window.sends, 1, "Enter sends");
            compare(field.text, "hello\nw", "and sending is the composer's to do, not a newline's");
        }

        // What Markdown needs: a code block pasted or typed keeps its lines.
        function test_the_field_keeps_newlines() {
            field.text = "```\nline one\nline two\n```";
            compare(field.text.split("\n").length, 4);
        }
    }
}
