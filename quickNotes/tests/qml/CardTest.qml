import QtQuick
import QtTest

// QuickNotesCard driven by real key presses, over the real sync engine with
// no network (FakeService.qml). Run by `node tests/quicknotes.test.js`, which
// copies this next to the plugin's files and gives qmltestrunner the stand-in
// qs.Common and qs.Widgets modules under stubs/.
//
// The rows, bottom (index 0) to top: gamma, beta, alpha; "ancient" is done
// a month ago and hidden.
Item {
    id: root

    property int closes: 0

    width: 800
    height: 700

    FakeService {
        id: svc
    }

    QuickNotesCard {
        id: card

        anchors.fill: parent
        service: svc
        onCloseRequested: root.closes++
    }

    TestCase {
        id: tc

        property var field: null

        function ctrl(key) {
            keyClick(key, Qt.ControlModifier);
        }

        function task(summary) {
            return svc.tasks.find(t => t.summary === summary) || null;
        }

        function uidOf(summary) {
            const t = task(summary);
            return t ? t.uid : "<" + summary + " not there>";
        }

        function shown(summary) {
            return card.rows.some(r => r.summary === summary);
        }

        function init() {
            field = findChild(card, "field");
            field.text = "";
            root.closes = 0;
            svc.seed();
            card.opened();
            tryVerify(() => tc.field.activeFocus, 3000, "the field has the keyboard");
        }

        function test_typing_goes_to_the_field_and_enter_adds() {
            keyClick(Qt.Key_H);
            keyClick(Qt.Key_I);
            compare(field.text, "hi");
            keyClick(Qt.Key_Return);
            compare(field.text, "");
            verify(task("hi"), "added");
            compare(card.rows[0].summary, "hi", "newest right above the field");
            compare(card.selectedUid, "");
            verify(task("hi").pending, "waiting to be sent");
        }

        function test_shift_enter_is_a_new_line_and_the_rest_are_notes() {
            field.text = "title";
            field.cursorPosition = 5;
            keyClick(Qt.Key_Return, Qt.ShiftModifier);
            compare(field.text, "title\n");
            keyClick(Qt.Key_N);
            keyClick(Qt.Key_O);
            compare(field.text, "title\nno");
            keyClick(Qt.Key_Return);
            const t = task("title");
            verify(t, "added");
            compare(t.description, "no");
        }

        function test_enter_on_blank_adds_nothing() {
            const n = svc.tasks.length;
            field.text = "  \n ";
            keyClick(Qt.Key_Return);
            compare(svc.tasks.length, n);
        }

        function test_ctrl_k_and_j_walk_the_list() {
            ctrl(Qt.Key_K);
            compare(card.selectedUid, uidOf("gamma"));
            ctrl(Qt.Key_K);
            compare(card.selectedUid, uidOf("beta"));
            ctrl(Qt.Key_K);
            compare(card.selectedUid, uidOf("alpha"));
            ctrl(Qt.Key_K);
            compare(card.selectedUid, uidOf("alpha"), "stops at the top");
            ctrl(Qt.Key_J);
            compare(card.selectedUid, uidOf("beta"));
            ctrl(Qt.Key_J);
            compare(card.selectedUid, uidOf("gamma"));
            ctrl(Qt.Key_J);
            compare(card.selectedUid, "", "back at the field");
            ctrl(Qt.Key_J);
            compare(card.selectedUid, "");
        }

        function test_ctrl_k_leaves_the_draft_alone() {
            field.text = "draft";
            field.cursorPosition = 0;
            ctrl(Qt.Key_K);
            compare(field.text, "draft", "not the field's delete-to-end-of-line");
            compare(card.selectedUid, uidOf("gamma"));
            ctrl(Qt.Key_J);
            compare(field.text, "draft");
        }

        function test_ctrl_enter_marks_done_and_back() {
            ctrl(Qt.Key_K);
            ctrl(Qt.Key_K);
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            verify(task("beta").completed, "done");
            compare(card.selectedUid, uidOf("beta"), "still selected");
            compare(card.rows[1].uid, uidOf("beta"), "still in its place");
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            verify(!task("beta").completed, "open again");
            compare(svc.status.waiting, 0, "back to what the server has: nothing to send");
        }

        function test_ctrl_enter_with_nothing_selected_does_nothing() {
            field.text = "x";
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            compare(field.text, "x");
            verify(!task("x"));
            verify(svc.tasks.every(t => !t.completed || t.summary === "ancient"));
        }

        function test_ctrl_delete_deletes_and_ctrl_z_brings_it_back() {
            ctrl(Qt.Key_K);
            ctrl(Qt.Key_K);
            const beta = uidOf("beta");
            keyClick(Qt.Key_Delete, Qt.ControlModifier);
            verify(!task("beta"), "gone at once");
            compare(card.selectedUid, uidOf("alpha"), "on the row that took its place");
            verify(card.undoActive);
            ctrl(Qt.Key_Z);
            verify(task("beta"), "back");
            compare(card.selectedUid, beta);
            verify(!card.undoActive);
            compare(svc.status.waiting, 0, "the delete never left");
        }

        function test_ctrl_delete_with_nothing_selected_is_the_fields() {
            const n = svc.tasks.length;
            field.text = "one two";
            field.cursorPosition = 0;
            keyClick(Qt.Key_Delete, Qt.ControlModifier);
            compare(svc.tasks.length, n, "no task deleted");
            verify(field.text !== "one two", "a word went instead");
        }

        function test_ctrl_z_is_the_fields_own_otherwise() {
            keyClick(Qt.Key_A);
            compare(field.text, "a");
            ctrl(Qt.Key_Z);
            compare(field.text, "", "typing undone");
        }

        function test_slash_searches_and_enter_lands_on_the_match() {
            keyClick(Qt.Key_Slash);
            verify(card.searching);
            keyClick(Qt.Key_B);
            keyClick(Qt.Key_E);
            compare(card.rows.length, 1);
            compare(card.selectedUid, uidOf("beta"), "the match is picked");
            keyClick(Qt.Key_Return);
            compare(field.text, "");
            verify(!card.searching);
            compare(card.selectedUid, uidOf("beta"), "still on it in the whole list");
            compare(card.rows.length, 3);
            verify(!task("/be"), "a search is never added as a task");
        }

        function test_search_finds_old_done_tasks_and_keeps_them_in_view() {
            verify(!shown("ancient"), "hidden: done a month ago");
            field.text = "/anc";
            compare(card.selectedUid, uidOf("ancient"));
            keyClick(Qt.Key_Return);
            compare(card.selectedUid, uidOf("ancient"));
            verify(shown("ancient"), "kept in view after the search");
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            verify(!task("ancient").completed, "and opened again right there");
        }

        function test_ctrl_enter_during_a_search_marks_the_match() {
            field.text = "/gam";
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            verify(task("gamma").completed);
            verify(card.searching, "still searching");
        }

        function test_search_ignores_case_and_accents() {
            svc.add("Çarşı İzni");
            field.text = "/carsi izni";
            compare(card.rows.length, 1);
            compare(card.rows[0].summary, "Çarşı İzni");
            field.text = "/NOTES";
            compare(card.rows.length, 1, "the notes are searched too");
            compare(card.rows[0].summary, "gamma");
        }

        function test_escape_steps_back_then_closes() {
            field.text = "/x";
            keyClick(Qt.Key_Escape);
            compare(field.text, "");
            compare(root.closes, 0);
            ctrl(Qt.Key_K);
            keyClick(Qt.Key_Escape);
            compare(card.selectedUid, "");
            compare(root.closes, 0);
            keyClick(Qt.Key_Escape);
            compare(root.closes, 1);
        }

        function test_arrows_walk_only_when_the_field_is_empty() {
            keyClick(Qt.Key_Up);
            compare(card.selectedUid, uidOf("gamma"));
            keyClick(Qt.Key_Down);
            compare(card.selectedUid, "");
            field.text = "a\nb";
            field.cursorPosition = 3;
            keyClick(Qt.Key_Up);
            compare(card.selectedUid, "", "with text there, Up moves the cursor");
        }

        function test_ctrl_r_syncs() {
            ctrl(Qt.Key_R);
            compare(svc.syncs, 1);
        }

        function test_reopening_keeps_a_draft_but_not_a_search() {
            field.text = "half typed";
            card.opened();
            compare(field.text, "half typed");
            field.text = "/search";
            card.opened();
            compare(field.text, "");
        }

        function test_done_in_this_sitting_stays_until_it_ends() {
            svc.keepDoneHours = 0;
            ctrl(Qt.Key_K);
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            verify(task("gamma").completed);
            verify(shown("gamma"), "stays while the window is open");
            card.opened();
            verify(!shown("gamma"), "gone once it opens again");
        }

        name: "QuickNotesCard"
        when: windowShown
    }
}
