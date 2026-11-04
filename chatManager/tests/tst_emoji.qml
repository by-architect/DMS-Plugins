import QtQuick
import QtTest
import "../emoji.js" as Emoji

// Finding emoji by name, and :shortcodes: turning into them as they are typed.
TestCase {
    name: "Emoji"

    function test_search() {
        compare(Emoji.search("thumbsup")[0], "👍");
        compare(Emoji.search(":+1:")[0], "👍", "a shortcode with its colons");
        compare(Emoji.search("fire")[0], "🔥");
        verify(Emoji.search("laugh", 10).indexOf("😆") !== -1, "found by a word of its name or tags");
        compare(Emoji.search("red heart")[0], "❤️", "every word of the query counts");
        compare(Emoji.search("").length, 0);
        compare(Emoji.search("zzzzqq").length, 0);
    }

    function test_shortcodes() {
        compare(Emoji.fromShortcode("joy"), "😂");
        compare(Emoji.fromShortcode(":heart:"), "❤️");
        compare(Emoji.fromShortcode("not_an_emoji"), "");
    }

    function test_replaceAtCursor() {
        const done = Emoji.replaceShortcodeAt("ha :joy:", 8);
        compare(done.text, "ha 😂");
        compare(done.cursor, 3 + "😂".length);

        const middle = Emoji.replaceShortcodeAt(":+1: later", 4);
        compare(middle.text, "👍 later");

        compare(Emoji.replaceShortcodeAt("at 10:30:", 9), null, "a time is not a shortcode");
        compare(Emoji.replaceShortcodeAt("half :thum", 10), null, "an unfinished one waits");
        compare(Emoji.replaceShortcodeAt("x:joy:", 6), null, "only at the start of a word");
        compare(Emoji.replaceShortcodeAt(":nope:", 6), null, "an unknown one stays text");
    }

    function test_resolve() {
        compare(Emoji.resolve("fire"), "🔥");
        compare(Emoji.resolve(":tada:"), "🎉");
        compare(Emoji.resolve("👍"), "👍", "an emoji typed is kept");
        compare(Emoji.resolve("  "), "");
    }
}
