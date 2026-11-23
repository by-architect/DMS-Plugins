import QtQuick
import QtTest
import "../search.js" as Search

// Lighting up what a search inside a conversation found. The chat manager
// says what matched, as each message writes it; these find it in the text a
// result row shows, the way the manager compares text.
TestCase {
    name: "Search"

    function test_fold_ignores_case_accents_and_the_turkish_i() {
        compare(Search.fold("İstanbul").text, "istanbul");
        compare(Search.fold("KIRMIZI kırmızı").text, "kirmizi kirmizi");
        compare(Search.fold("Çay ŞEKER ğüö").text, "cay seker guo");
        compare(Search.fold("Straße").text, "strasse");
        compare(Search.fold("İstanbul’da").text, "istanbul'da");
        compare(Search.fold("two\n\n  lines").text, "two lines");
        compare(Search.fold("café").text, "cafe");
    }

    function test_fold_knows_where_each_character_came_from() {
        const f = Search.fold("Aß😂b");
        compare(f.text, "ass😂b");
        compare(f.at.slice(0, 3), [0, 1, 1], "both halves of ß are the ß");
        compare(f.at[f.text.length - 1], 4, "b is after the emoji's two halves");
    }

    function test_ranges_find_every_mark_as_written() {
        const text = "Yarın İSTANBUL'da, sonra istanbul";
        compare(Search.ranges(text, ["İstanbul"]), [[6, 14], [25, 33]]);
        compare(Search.ranges(text, ["istanbul", "yarin"]), [[0, 5], [6, 14], [25, 33]], "in order");
        compare(Search.ranges("abc", ["zz"]), []);
        compare(Search.ranges("abc", [""]), [], "an empty mark lights nothing");
    }

    function test_ranges_join_what_overlaps() {
        compare(Search.ranges("toplantıda", ["toplan", "plantı"]), [[0, 8]]);
    }

    function test_ranges_take_the_accent_after_a_letter() {
        compare(Search.ranges("café au lait", ["cafe"]), [[0, 5]]);
    }

    function test_snippet_lights_up_and_escapes() {
        const out = Search.snippet("a <b> & İstanbul", Search.ranges("a <b> & İstanbul", ["istanbul"]), "#ff0000", 50, 160);
        compare(out, "a &lt;b&gt; &amp; <b><font color=\"#ff0000\">İstanbul</font></b>");
    }

    function test_snippet_is_a_stretch_around_the_first_match() {
        const text = "x".repeat(100) + " found " + "y".repeat(300);
        const out = Search.snippet(text, Search.ranges(text, ["found"]), "#000", 10, 40);
        verify(out.startsWith("…xxxxxxxxx"), "leads up to the match: " + out);
        verify(out.indexOf(">found<") > 0);
        verify(out.endsWith("…"));
    }

    function test_snippet_never_cuts_an_emoji_in_half() {
        const text = "😂".repeat(30) + "match";
        const out = Search.snippet(text, Search.ranges(text, ["match"]), "#000", 5, 20);
        verify(out.charCodeAt(1) < 0xdc00 || out.charCodeAt(1) > 0xdfff, "starts on a whole emoji");
    }

    function test_snippet_without_a_match_is_the_start() {
        compare(Search.snippet("short", [], "#000", 50, 160), "short");
        compare(Search.snippet("abcdef", [], "#000", 50, 3), "abc…");
    }
}
