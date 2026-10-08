import QtQuick
import QtTest
import "../markdown.js" as Md

// What a message's formatting turns into.
//
// The first group is the one that matters most: the text is somebody else's,
// so formatting must never become a way to put markup, images or non-web links
// into the window. The rest pin down the dialects -- including the cases that
// must stay plain, which is where a renderer like this goes wrong in practice.
TestCase {
    name: "MessageMarkdown"

    readonly property var colors: ({
            "text": "#cccccc",
            "dim": "#999999",
            "link": "#00ff00",
            "quoteBar": "#0000ff",
            "codeBg": "#111111",
            "inlineCodeBg": "#222222",
            "border": "#333333",
            "mono": "Mono",
            "fontSize": 14
        })

    function md(text) {
        return Md.render(text, "markdown", colors);
    }

    function wa(text) {
        return Md.render(text, "whatsapp", colors);
    }

    // ------------------------------------------------------------- safety

    function test_markup_in_a_message_is_not_markup() {
        for (const out of [md("<img src=\"https://x/y.png\"><b>hi</b>"), wa("<img src=x><b>hi</b>")]) {
            verify(!out.includes("<img"), out);
            verify(!out.includes("<b>hi"), out);
            verify(out.includes("&lt;img"), out);
        }
    }

    function test_a_link_to_anything_but_the_web_stays_text() {
        const out = md("[click](javascript:alert(1)) and [file](file:///etc/passwd)");
        verify(!out.includes("<a"), out);
        verify(out.includes("[click](javascript:alert(1))"), out);
    }

    function test_an_image_is_never_loaded() {
        const out = md("![cat](https://example.org/cat.png)");
        verify(!out.includes("<img"), out);
        verify(out.includes("href=\"https://example.org/cat.png\""), out);
    }

    function test_a_url_cannot_climb_out_of_its_attribute() {
        const out = md("[x](https://example.org/\"onmouseover=\"y)");
        verify(out.split("href=\"").length <= 2, out);
        verify(!out.includes("onmouseover=\""), out);
    }

    function test_html_inside_code_is_escaped() {
        const out = md("`<b>x</b>`\n```\n<script>alert(1)</script>\n```");
        verify(!out.includes("<script>"), out);
        verify(out.includes("&lt;script&gt;"), out);
        verify(out.includes("&lt;b&gt;x&lt;/b&gt;"), out);
    }

    // ----------------------------------------------------------- markdown

    function test_emphasis() {
        compare(md("**bold** *italic* _also_ ~~gone~~"), "<b>bold</b> <i>italic</i> <i>also</i> <s>gone</s>");
    }

    function test_bold_and_italic_nest() {
        compare(md("***both***"), "<i><b>both</b></i>");
        compare(md("**bold *and italic* bold**"), "<b>bold <i>and italic</i> bold</b>");
    }

    function test_snake_case_is_not_italic() {
        compare(md("call my_function_name now"), "call my_function_name now");
    }

    function test_spaced_stars_are_stars() {
        compare(md("a * b * c"), "a * b * c");
    }

    function test_a_lone_marker_is_literal() {
        compare(md("5 * 3 and **open"), "5 * 3 and **open");
    }

    function test_backslash_escapes() {
        compare(md("\\*not italic\\*"), "*not italic*");
    }

    function test_code_span_protects_its_contents() {
        const out = md("run `a*b*c` now");
        verify(out.includes("a*b*c"), out);
        verify(!out.includes("<i>"), out);
        verify(out.includes("font-family:'Mono'"), out);
    }

    function test_a_url_keeps_its_underscores() {
        const out = md("see https://example.org/a_b_c_d and _this_");
        verify(out.includes("href=\"https://example.org/a_b_c_d\""), out);
        verify(out.endsWith("<i>this</i>"), out);
    }

    function test_web_link() {
        const out = md("read [the **docs**](https://example.org/docs) first");
        verify(out.includes("<a href=\"https://example.org/docs\""), out);
        verify(out.includes("the <b>docs</b></a>"), out);
    }

    function test_angle_autolink() {
        verify(md("<https://example.org>").includes("href=\"https://example.org\""));
    }

    function test_fenced_code_block() {
        const out = md("before\n```go\nx := a*b*c\n  indented\n```\nafter");
        verify(out.startsWith("before<table"), out);
        verify(out.includes("<pre style=\"font-family:'Mono',monospace; white-space:pre-wrap;\">x := a*b*c\n  indented</pre>"), out);
        verify(out.endsWith("</table>after"), out);
    }

    function test_an_unclosed_fence_runs_to_the_end() {
        const out = md("```\ncode");
        verify(out.includes(">code</pre>"), out);
    }

    function test_heading() {
        const out = md("# Title\nbody");
        verify(out.startsWith("<span style=\"font-size:20px; font-weight:600;\">Title</span><br>body"), out);
    }

    function test_hashtag_is_not_a_heading() {
        compare(md("#nofilter"), "#nofilter");
    }

    function test_quote_draws_a_bar_per_line() {
        const out = md("> first\n> second\nafter");
        compare(out.split("▍").length - 1, 2);
        verify(out.endsWith("<br>after"), out);
    }

    function test_nested_quote() {
        verify(md("> > deep").includes("▍▍"));
    }

    function test_bullet_list() {
        const out = md("- one\n- **two**");
        verify(out.startsWith("<ul"), out);
        verify(out.includes("<li>one</li><li><b>two</b></li></ul>"), out);
    }

    function test_numbered_list_keeps_its_first_number() {
        const out = md("3. third\n4. fourth");
        verify(out.startsWith("<ol start=\"3\""), out);
        verify(md("1. first").startsWith("<ol style"), md("1. first"));
    }

    function test_nested_list() {
        const out = md("- a\n  - b\n- c");
        verify(out.includes("<li>a<ul"), out);
        verify(out.includes("<li>b</li></ul></li><li>c</li>"), out);
    }

    function test_table() {
        const out = md("| Name | n |\n|:--|--:|\n| a | 1 |");
        verify(out.includes("<th align=\"left\">Name</th><th align=\"right\">n</th>"), out);
        verify(out.includes("<td align=\"left\">a</td><td align=\"right\">1</td>"), out);
    }

    function test_rule() {
        compare(md("above\n\n---\nbelow"), "above<hr>below");
    }

    function test_line_breaks_and_paragraphs() {
        compare(md("one\ntwo\n\nthree"), "one<br>two<br><br>three");
    }

    function test_runs_of_spaces_survive() {
        verify(md("a    b").includes("&nbsp;"));
    }

    // ----------------------------------------------------------- whatsapp

    function test_whatsapp_markers() {
        compare(wa("*bold* _italic_ ~gone~"), "<b>bold</b> <i>italic</i> <s>gone</s>");
    }

    function test_whatsapp_takes_markdown_bold_too() {
        compare(wa("**bold**"), "<b>bold</b>");
    }

    function test_whatsapp_needs_word_boundaries() {
        compare(wa("2*3*4 and a_b_c"), "2*3*4 and a_b_c");
    }

    function test_whatsapp_monospace() {
        verify(wa("```mono```").includes("font-family:'Mono'"));
    }

    function test_whatsapp_has_no_headings_or_markdown_links() {
        compare(wa("# not a heading"), "# not a heading");
        const out = wa("[x](https://example.org)");
        verify(out.startsWith("[x]("), out);
        verify(out.includes("href=\"https://example.org\""), out);
    }

    function test_whatsapp_quote_and_list() {
        verify(wa("> quoted").includes("▍"));
        verify(wa("- item\n- item").startsWith("<ul"));
    }

    // ---------------------------------------------------------- fallbacks

    function test_unknown_dialect_is_plain_text_with_links() {
        compare(Md.render("**x** https://example.org", "", colors), "**x** <a href=\"https://example.org\" style=\"color:#00ff00\">https://example.org</a>");
    }

    // -------------------------------------------------------------- plain

    function test_plain_takes_the_formatting_off() {
        compare(Md.plain("**Hello** _there_ `code` [docs](https://example.org)", "markdown"), "Hello there code docs");
        compare(Md.plain("*bold* _it_", "whatsapp"), "bold it");
        compare(Md.plain("```\nx = 1\n```", "markdown"), "x = 1");
        compare(Md.plain("# Title\n- a\n- b", "markdown"), "Title\n• a\n• b");
        compare(Md.plain("> quoted", "markdown"), "quoted");
        compare(Md.plain("**x**", ""), "**x**");
    }
}
