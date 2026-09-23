import QtQuick
import QtTest
import "../links.js" as Links

// What a message is allowed to render and open.
//
// Every case here is something a sender can choose, so each one is a thing
// somebody could send on purpose rather than a thing that might happen.
TestCase {
    name: "MessageLinks"

    function test_markup_in_a_message_is_not_markup() {
        const value = Links.render("<img src=\"file:///etc/passwd\"><b>hello</b>", "#00ff00");
        verify(!value.includes("<img"));
        verify(!value.includes("<b>"));
        verify(value.includes("&lt;img"));
    }

    // The quote is the one that matters: the url is written into an href, so a
    // url allowed to contain a quote can close the attribute and start another.
    function test_a_url_cannot_climb_out_of_its_attribute() {
        const value = Links.render("https://example.org/\" href=\"file:///etc/passwd", "#00ff00");
        verify(!value.includes("href=\"file:"));
        // Exactly one real href: the injected one survives only as text, with
        // its quote escaped, so it can never be an attribute.
        verify(value.split("href=\"").length === 2);
        verify(value.includes("&quot;"));
    }

    function test_the_link_keeps_its_query() {
        const value = Links.render("https://example.org/?a=1&b=2", "#00ff00");
        verify(value.includes("href=\"https://example.org/?a=1&amp;b=2\""));
    }

    // A link at the end of a sentence collects the full stop; one in brackets
    // collects the bracket -- unless it opened that bracket itself.
    function test_the_sentence_is_not_part_of_the_link() {
        const value = Links.render("See (https://example.org/hello).", "#00ff00");
        verify(value.includes("href=\"https://example.org/hello\""));
        verify(value.endsWith("</a>)."));
        verify(Links.render("https://example.org/Hello_(world)", "#00ff00").includes("href=\"https://example.org/Hello_(world)\""));
    }

    function test_only_the_web_may_be_opened() {
        verify(Links.isWebUrl("https://example.org"));
        verify(Links.isWebUrl("http://example.org"));
        verify(!Links.isWebUrl("javascript:alert(1)"));
        verify(!Links.isWebUrl("file:///etc/passwd"));
        verify(!Links.isWebUrl("ms-msdt:/id"));
        verify(!Links.isWebUrl("https://example.org\ncommand"));
        verify(!Links.isWebUrl(""));
    }

    function test_newlines_survive_as_line_breaks() {
        compare(Links.render("one\ntwo", "#00ff00"), "one<br>two");
    }

    // What the key that opens the selected message acts on.
    function test_the_first_link_is_the_one_opened() {
        compare(Links.firstWebUrl("read https://example.org/one and https://example.org/two"), "https://example.org/one");
        compare(Links.firstWebUrl("see https://example.org/page."), "https://example.org/page");
        compare(Links.firstWebUrl("nothing here"), "");
        compare(Links.firstWebUrl("file:///etc/passwd"), "");
    }
}
