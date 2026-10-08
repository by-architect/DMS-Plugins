.pragma library
.import "links.js" as Links

// A message's text as formatted markup, and as plain text for one-line
// previews.
//
// Which formatting a message uses is the provider's: a bridge declares it in
// its capabilities, and the bubble passes it in as the dialect.
//
//   "markdown"  CommonMark as chat clients write it: **bold**, *italic*,
//               ~~strike~~, `code`, fenced code blocks, headings, quotes,
//               lists, tables, [links](https://...). Every newline is a line
//               break, as in Element. Matrix and Signal.
//   "whatsapp"  WhatsApp's own: *bold*, _italic_, ~strike~, `code`, ```mono```,
//               > quotes and - or 1. lists. A *word* has to look here the way it
//               looks on the phone. **double** is taken as bold as well, so
//               Markdown typed into a WhatsApp chat still reads right.
//   anything else: plain text, links clickable -- what every message was before.
//
// Message text is somebody else's input, so nothing in it is ever markup: all
// of it is escaped, the only tags are the ones written here, and a link is a
// link only if Links.isWebUrl lets it be one -- [x](javascript:...) stays the
// text it was typed as. Images are never loaded: ![alt](url) is a link.
//
// The output is Qt rich text (Text.RichText), which is why a code block is a
// one-cell table -- the only block Qt fills with a background colour -- and a
// quote is a glyph bar on every line: a table cell's background stops at the
// first line, so a bar drawn that way did not reach the bottom of the quote.

// --------------------------------------------------------------- helpers

function escapeHtml(value) {
    return Links.escapeHtml(value);
}

// Runs of spaces and tabs survive: HTML would fold "a   b" into "a b", and
// people align things in chat.
function _keepSpaces(html) {
    return html.replace(/\t/g, "    ").replace(/ {2,}/g, function (run) {
        var out = "";
        for (var i = 0; i < run.length; i++)
            out += i % 2 === 0 ? "&nbsp;" : " ";
        return out;
    });
}

var _ASCII_PUNCT = /[!-\/:-@\[-`{-~]/;
// ASCII punctuation plus the general punctuation and CJK symbol blocks, which
// is what decides whether an emphasis marker touching a quote mark or a
// bracket may open or close.
var _PUNCT = /[!-\/:-@\[-`{-~¡-¿‐-‧‰-⁞⸀-⹿　-〿]/;

function _isSpace(ch) {
    return ch === "" || /\s/.test(ch);
}

function _isPunct(ch) {
    return ch !== "" && _PUNCT.test(ch);
}

function _color(c) {
    return escapeHtml(String(c || ""));
}

// ---------------------------------------------------------------- inline

// _inlineNodes splits a line into what can be decided on its own -- code
// spans, links, escaped characters, plain text -- and the runs of * _ ~ whose
// meaning depends on what else is on the line. Code and links are atoms:
// nothing inside a URL or a code span is ever taken as emphasis, which is
// what keeps snake_case URLs and `a*b*c` code intact.
function _inlineNodes(src, dialect, opts) {
    var md = dialect === "markdown";
    var nodes = [];
    var text = "";
    var i = 0;

    function flush() {
        if (text !== "") {
            nodes.push({ kind: "text", value: text });
            text = "";
        }
    }

    while (i < src.length) {
        var ch = src[i];

        // Code span: a run of backticks up to the next run of the same length.
        if (ch === "`") {
            var run = 1;
            while (src[i + run] === "`")
                run++;
            var close = -1;
            var j = i + run;
            while (j < src.length) {
                if (src[j] === "`") {
                    var r = 1;
                    while (src[j + r] === "`")
                        r++;
                    if (r === run) {
                        close = j;
                        break;
                    }
                    j += r;
                } else {
                    j++;
                }
            }
            if (close >= 0) {
                var code = src.slice(i + run, close).replace(/\n/g, " ");
                if (code.length > 2 && code[0] === " " && code[code.length - 1] === " " && code.trim() !== "")
                    code = code.slice(1, -1);
                flush();
                nodes.push({ kind: "code", value: code });
                i = close + run;
                continue;
            }
            text += src.slice(i, i + run);
            i += run;
            continue;
        }

        // Backslash escape, Markdown only: WhatsApp has none, and a lone
        // backslash there is just a backslash.
        if (md && ch === "\\" && i + 1 < src.length && _ASCII_PUNCT.test(src[i + 1])) {
            flush();
            nodes.push({ kind: "text", value: src[i + 1], literal: true });
            i += 2;
            continue;
        }

        // [label](url) and ![alt](url), Markdown only.
        if (md && !opts.noLinks && (ch === "[" || (ch === "!" && src[i + 1] === "["))) {
            var link = _parseLink(src, ch === "!" ? i + 1 : i);
            if (link) {
                flush();
                nodes.push({ kind: "link", label: link.label, url: link.url, image: ch === "!", source: src.slice(i, link.end) });
                i = link.end;
                continue;
            }
        }

        // <https://...>, Markdown only.
        if (md && !opts.noLinks && ch === "<") {
            var auto = /^<(https?:\/\/[^\s<>]+)>/i.exec(src.slice(i));
            if (auto) {
                flush();
                nodes.push({ kind: "url", url: auto[1] });
                i += auto[0].length;
                continue;
            }
        }

        // A bare URL, in every dialect, the way links.js has always found them.
        if (!opts.noLinks && (ch === "h" || ch === "H") && (i === 0 || !/[A-Za-z0-9]/.test(src[i - 1]))) {
            var m = /^https?:\/\/[^\s<>"']+/i.exec(src.slice(i));
            if (m) {
                var url = Links._trim(m[0]);
                flush();
                nodes.push({ kind: "url", url: url });
                i += url.length;
                continue;
            }
        }

        // A run of emphasis markers.
        if (ch === "*" || ch === "_" || ch === "~") {
            var n = 1;
            while (src[i + n] === ch)
                n++;
            var before = i > 0 ? src[i - 1] : "";
            var after = i + n < src.length ? src[i + n] : "";
            flush();
            nodes.push(_delimiter(ch, n, before, after, dialect));
            i += n;
            continue;
        }

        text += ch;
        i++;
    }
    flush();
    return nodes;
}

// CommonMark's flanking rules, which are what tell "2*3*4" from "a * b * c"
// and keep snake_case_names from turning italic. WhatsApp is stricter: a
// marker only counts at a word boundary, for every marker, the way the app
// itself decides it.
function _delimiter(ch, n, before, after, dialect) {
    var leftFlanking = !_isSpace(after) && (!_isPunct(after) || _isSpace(before) || _isPunct(before));
    var rightFlanking = !_isSpace(before) && (!_isPunct(before) || _isSpace(after) || _isPunct(after));
    var canOpen;
    var canClose;
    if (dialect === "whatsapp" || ch === "_") {
        canOpen = leftFlanking && (!rightFlanking || _isPunct(before));
        canClose = rightFlanking && (!leftFlanking || _isPunct(after));
    } else {
        canOpen = leftFlanking;
        canClose = rightFlanking;
    }
    return {
        kind: "delim",
        ch: ch,
        n: n,
        orig: n,
        canOpen: canOpen,
        canClose: canClose,
        active: true
    };
}

// [label](url "title") starting at i (the "["). Brackets inside the label may
// nest; the URL may hold balanced parentheses, as Wikipedia's do.
function _parseLink(src, i) {
    var depth = 0;
    var j = i;
    for (; j < src.length; j++) {
        var c = src[j];
        if (c === "\\") {
            j++;
            continue;
        }
        if (c === "[")
            depth++;
        else if (c === "]") {
            depth--;
            if (depth === 0)
                break;
        } else if (c === "\n") {
            return null;
        }
    }
    if (depth !== 0 || src[j + 1] !== "(")
        return null;
    var label = src.slice(i + 1, j);
    var k = j + 2;
    while (src[k] === " ")
        k++;
    var angled = src[k] === "<";
    if (angled)
        k++;
    var start = k;
    var parens = 0;
    for (; k < src.length; k++) {
        var d = src[k];
        if (angled) {
            if (d === ">")
                break;
            if (d === "\n" || d === "<")
                return null;
            continue;
        }
        if (d === " " || d === "\n")
            break;
        if (d === "(")
            parens++;
        else if (d === ")") {
            if (parens === 0)
                break;
            parens--;
        }
    }
    var url = src.slice(start, k);
    if (angled) {
        if (src[k] !== ">")
            return null;
        k++;
    }
    // An optional "title", which is dropped.
    var rest = /^\s*(?:"[^"\n]*"|'[^'\n]*')?\s*\)/.exec(src.slice(k));
    if (!rest || url === "")
        return null;
    return {
        label: label,
        url: url,
        end: k + rest[0].length
    };
}

// CommonMark's "process emphasis", over the node list: each closer, left to
// right, finds the nearest opener of the same character it may pair with, and
// the pair turns into tags around everything between. Whatever is left over
// stays literal, which is how a lone * reads as a star.
function _processEmphasis(nodes, dialect) {
    var md = dialect === "markdown";
    var ci = 0;
    while (ci < nodes.length) {
        var c = nodes[ci];
        if (c.kind !== "delim" || !c.active || !c.canClose || c.n === 0) {
            ci++;
            continue;
        }
        var found = -1;
        for (var oi = ci - 1; oi >= 0; oi--) {
            var o = nodes[oi];
            if (o.kind !== "delim" || !o.active || o.ch !== c.ch || !o.canOpen || o.n === 0)
                continue;
            // The "rule of three", which keeps *foo**bar** from pairing the
            // wrong markers.
            if (md && c.ch !== "~" && (o.canClose || c.canOpen) && (o.orig + c.orig) % 3 === 0 && !(o.orig % 3 === 0 && c.orig % 3 === 0))
                continue;
            found = oi;
            break;
        }
        if (found < 0) {
            ci++;
            continue;
        }
        var op = nodes[found];
        var use;
        var tag;
        if (c.ch === "~") {
            // GFM wants two tildes; WhatsApp uses one.
            if (md) {
                if (op.n < 2 || c.n < 2) {
                    ci++;
                    continue;
                }
                use = 2;
            } else {
                use = op.n >= 2 && c.n >= 2 ? 2 : 1;
            }
            tag = "s";
        } else {
            use = op.n >= 2 && c.n >= 2 ? 2 : 1;
            if (md)
                tag = use === 2 ? "b" : "i";
            else
                tag = c.ch === "*" ? "b" : "i";
        }
        op.n -= use;
        c.n -= use;
        // What sits between the pair can no longer pair with anything outside.
        for (var k = found + 1; k < ci; k++) {
            if (nodes[k].kind === "delim")
                nodes[k].active = false;
        }
        nodes.splice(found + 1, 0, { kind: "open", tag: tag });
        ci++;
        nodes.splice(ci, 0, { kind: "close", tag: tag });
        ci++;
        if (c.n === 0)
            ci++;
    }
}

function _repeat(ch, n) {
    var s = "";
    for (var i = 0; i < n; i++)
        s += ch;
    return s;
}

function _inline(src, dialect, ctx, opts) {
    opts = opts || {};
    var nodes = _inlineNodes(src, dialect, opts);
    _processEmphasis(nodes, dialect);

    var out = "";
    for (var i = 0; i < nodes.length; i++) {
        var nd = nodes[i];
        switch (nd.kind) {
        case "text":
            out += ctx.plain ? nd.value : _keepSpaces(escapeHtml(nd.value));
            break;
        case "delim":
            out += ctx.plain ? _repeat(nd.ch, nd.n) : escapeHtml(_repeat(nd.ch, nd.n));
            break;
        case "open":
            out += ctx.plain ? "" : "<" + nd.tag + ">";
            break;
        case "close":
            out += ctx.plain ? "" : "</" + nd.tag + ">";
            break;
        case "code":
            out += ctx.plain ? nd.value : "<span style=\"font-family:'" + _color(ctx.mono) + "',monospace; background-color:" + _color(ctx.inlineCodeBg) + ";\">&nbsp;" + escapeHtml(nd.value).replace(/ /g, "&nbsp;") + "&nbsp;</span>";
            break;
        case "url":
            out += ctx.plain ? nd.url : _anchor(nd.url, escapeHtml(nd.url), ctx);
            break;
        case "link":
            if (!Links.isWebUrl(nd.url)) {
                // Not a web address: shown as typed, and not openable.
                out += ctx.plain ? nd.source : _keepSpaces(escapeHtml(nd.source));
                break;
            }
            var label = nd.label.trim() !== "" ? nd.label : nd.url;
            var inner = _inline(label, dialect, ctx, { noLinks: true });
            if (nd.image && !ctx.plain)
                inner = "🖼 " + inner;
            out += ctx.plain ? inner : _anchor(nd.url, inner, ctx);
            break;
        }
    }
    return out;
}

function _anchor(url, innerHtml, ctx) {
    return "<a href=\"" + escapeHtml(url) + "\" style=\"color:" + _color(ctx.link) + ";\">" + innerHtml + "</a>";
}

// ----------------------------------------------------------------- blocks

var _FENCE = /^ {0,3}(`{3,}|~{3,})[ \t]*([^`\s]*)[^`]*$/;
var _HEADING = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
var _RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
var _QUOTE = /^ {0,3}>[ ]?(.*)$/;
var _BULLET = /^([ \t]*)([-*+•])[ \t]+(.*)$/;
var _ORDERED = /^([ \t]*)(\d{1,9})([.)])[ \t]+(.*)$/;
var _TABLE_RULE = /^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(\|[ \t]*:?-{2,}:?[ \t]*)*\|?[ \t]*$/;

function _indentOf(ws) {
    return ws.replace(/\t/g, "    ").length;
}

function _splitRow(line) {
    var s = line.trim();
    if (s.startsWith("|"))
        s = s.slice(1);
    if (s.endsWith("|") && !s.endsWith("\\|"))
        s = s.slice(0, -1);
    var cells = [];
    var cur = "";
    for (var i = 0; i < s.length; i++) {
        if (s[i] === "\\" && s[i + 1] === "|") {
            cur += "|";
            i++;
        } else if (s[i] === "|") {
            cells.push(cur.trim());
            cur = "";
        } else {
            cur += s[i];
        }
    }
    cells.push(cur.trim());
    return cells;
}

// _blocks reads the text a line at a time into the blocks it is made of.
// Anything that is not one of the recognised shapes is a paragraph, line
// breaks kept -- so plain text comes out exactly as it went in.
function _blocks(text, dialect) {
    var md = dialect === "markdown";
    var lines = String(text).replace(/\r\n?/g, "\n").split("\n");
    var blocks = [];
    var i = 0;
    var gap = false;

    function push(b) {
        b.gapBefore = gap && blocks.length > 0;
        gap = false;
        blocks.push(b);
    }

    while (i < lines.length) {
        var line = lines[i];

        if (line.trim() === "") {
            gap = true;
            i++;
            continue;
        }

        var fence = _FENCE.exec(line);
        if (fence) {
            var marker = fence[1];
            var body = [];
            i++;
            while (i < lines.length) {
                var closing = new RegExp("^ {0,3}" + (marker[0] === "`" ? "`" : "~") + "{" + marker.length + ",}[ \\t]*$");
                if (closing.test(lines[i]))
                    break;
                body.push(lines[i]);
                i++;
            }
            i++; // the closing fence, or past the end
            push({ type: "code", lang: fence[2] || "", lines: body });
            continue;
        }

        if (md) {
            var h = _HEADING.exec(line);
            if (h) {
                push({ type: "heading", level: h[1].length, text: h[2] || "" });
                i++;
                continue;
            }
            if (_RULE.test(line)) {
                push({ type: "rule" });
                i++;
                continue;
            }
            if (line.indexOf("|") !== -1 && i + 1 < lines.length && _TABLE_RULE.test(lines[i + 1]) && lines[i + 1].indexOf("-") !== -1) {
                var header = _splitRow(line);
                var aligns = _splitRow(lines[i + 1]).map(function (c) {
                    var l = c.startsWith(":");
                    var r = c.endsWith(":");
                    return l && r ? "center" : (r ? "right" : (l ? "left" : ""));
                });
                var rows = [];
                i += 2;
                while (i < lines.length && lines[i].trim() !== "" && lines[i].indexOf("|") !== -1) {
                    rows.push(_splitRow(lines[i]));
                    i++;
                }
                push({ type: "table", header: header, aligns: aligns, rows: rows });
                continue;
            }
        }

        if (_QUOTE.test(line)) {
            var quoted = [];
            while (i < lines.length && _QUOTE.test(lines[i])) {
                // Nested quotes are counted, so "> > x" draws two bars.
                var depth = 0;
                var rest = lines[i];
                var q;
                while ((q = _QUOTE.exec(rest)) !== null) {
                    depth++;
                    rest = q[1];
                }
                quoted.push({ depth: depth, text: rest });
                i++;
            }
            push({ type: "quote", lines: quoted });
            continue;
        }

        if (_BULLET.test(line) || _ORDERED.test(line)) {
            var items = [];
            while (i < lines.length) {
                var b = _BULLET.exec(lines[i]);
                var o = b ? null : _ORDERED.exec(lines[i]);
                if (b) {
                    items.push({ indent: _indentOf(b[1]), ordered: false, text: b[3] });
                } else if (o) {
                    items.push({ indent: _indentOf(o[1]), ordered: true, number: parseInt(o[2], 10), delim: o[3], text: o[4] });
                } else if (lines[i].trim() !== "" && /^[ \t]{2,}\S/.test(lines[i]) && items.length > 0) {
                    // An indented line under an item continues it.
                    items[items.length - 1].text += "\n" + lines[i].trim();
                } else {
                    break;
                }
                i++;
            }
            push({ type: "list", items: items });
            continue;
        }

        var para = [];
        while (i < lines.length && lines[i].trim() !== "") {
            var l = lines[i];
            if (para.length > 0 && (_FENCE.test(l) || _QUOTE.test(l) || _BULLET.test(l) || _ORDERED.test(l) || (md && (_HEADING.test(l) || _RULE.test(l)))))
                break;
            para.push(l);
            i++;
        }
        push({ type: "para", lines: para });
    }
    return blocks;
}

function _renderList(items, dialect, ctx) {
    // Nesting by indentation: an item indented past the previous one starts
    // a list inside it.
    var html = "";
    var stack = [];

    function openList(item) {
        var tag = item.ordered ? "ol" : "ul";
        // Qt honours start= on <ol>, so "3. third" on its own still says 3.
        var start = item.ordered && item.number !== 1 ? " start=\"" + item.number + "\"" : "";
        // Qt indents a list 40px per level, which is a lot in a bubble; every
        // list is pulled back by 20px, which leaves 20px a level. Qt works out
        // the level of a nested list itself -- setting -qt-list-indent on one
        // as well put it in line with its parent.
        var level = stack.length === 0 ? " -qt-list-indent:1;" : "";
        html += "<" + tag + start + " style=\"margin-top:2px; margin-bottom:2px; margin-left:-20px;" + level + "\">";
        stack.push({ tag: tag, indent: item.indent, open: false });
    }

    for (var i = 0; i < items.length; i++) {
        var it = items[i];
        if (stack.length === 0) {
            openList(it);
        } else {
            var top = stack[stack.length - 1];
            if (it.indent > top.indent + 1 && top.open) {
                openList(it);
            } else {
                while (stack.length > 1 && it.indent < stack[stack.length - 1].indent) {
                    var popped = stack.pop();
                    if (popped.open)
                        html += "</li>";
                    html += "</" + popped.tag + ">";
                }
                top = stack[stack.length - 1];
                if (top.open) {
                    html += "</li>";
                    top.open = false;
                }
                if (top.tag !== (it.ordered ? "ol" : "ul")) {
                    // A bullet list running straight into a numbered one.
                    html += "</" + top.tag + ">";
                    stack.pop();
                    openList(it);
                }
            }
        }
        html += "<li>" + _inline(it.text, dialect, ctx).replace(/\n/g, "<br>");
        stack[stack.length - 1].open = true;
    }
    while (stack.length > 0) {
        var s = stack.pop();
        if (s.open)
            html += "</li>";
        html += "</" + s.tag + ">";
    }
    return html;
}

function _renderBlock(b, dialect, ctx) {
    switch (b.type) {
    case "code":
        // Qt's tab stops are eight spaces wide, which pushes indented code
        // off the side of a bubble.
        var code = b.lines.join("\n").replace(/\t/g, "    ");
        return "<table cellspacing=\"0\" cellpadding=\"8\" style=\"background-color:" + _color(ctx.codeBg) + ";\"><tr><td><pre style=\"font-family:'" + _color(ctx.mono) + "',monospace; white-space:pre-wrap;\">" + (code === "" ? " " : escapeHtml(code)) + "</pre></td></tr></table>";
    case "heading":
        var scale = [0, 1.4, 1.25, 1.12, 1.05, 1, 1][b.level];
        return "<span style=\"font-size:" + Math.round(ctx.fontSize * scale) + "px; font-weight:600;\">" + _inline(b.text, dialect, ctx) + "</span>";
    case "rule":
        return "<hr>";
    case "quote":
        return b.lines.map(function (q) {
            return "<span style=\"color:" + _color(ctx.quoteBar) + ";\">" + _repeat("▍", q.depth) + "</span> <span style=\"color:" + _color(ctx.dim) + ";\">" + _inline(q.text, dialect, ctx) + "</span>";
        }).join("<br>");
    case "list":
        return _renderList(b.items, dialect, ctx);
    case "table":
        var cols = b.header.length;
        var row = function (cells, tag) {
            var out = "<tr>";
            for (var c = 0; c < cols; c++) {
                var align = b.aligns[c] ? " align=\"" + b.aligns[c] + "\"" : "";
                out += "<" + tag + align + ">" + _inline(cells[c] || "", dialect, ctx) + "</" + tag + ">";
            }
            return out + "</tr>";
        };
        var html = "<table border=\"1\" cellspacing=\"0\" cellpadding=\"4\" style=\"border-color:" + _color(ctx.border) + "; border-style:solid;\">" + row(b.header, "th");
        for (var r = 0; r < b.rows.length; r++)
            html += row(b.rows[r], "td");
        return html + "</table>";
    default:
        return _inline(b.lines.join("\n"), dialect, ctx).replace(/\n/g, "<br>");
    }
}

// Blocks Qt lays out as blocks of their own; the rest are runs of text that
// need a line break between them.
function _isBlockElement(b) {
    return b.type === "code" || b.type === "list" || b.type === "table" || b.type === "rule";
}

// ------------------------------------------------------------------ public

// render: the text as Qt rich text. colors carries what the bubble looks like:
//   text, dim, link, quoteBar, codeBg, inlineCodeBg, border (colour strings),
//   mono (font family), fontSize (px).
function render(text, dialect, colors) {
    var value = String(text || "");
    if (dialect !== "markdown" && dialect !== "whatsapp")
        return Links.render(value, colors && colors.link ? colors.link : "");

    var ctx = {
        plain: false,
        dim: colors.dim,
        link: colors.link,
        quoteBar: colors.quoteBar || colors.link,
        codeBg: colors.codeBg,
        inlineCodeBg: colors.inlineCodeBg,
        border: colors.border || colors.dim,
        mono: colors.mono || "monospace",
        fontSize: colors.fontSize || 14
    };

    var blocks = _blocks(value, dialect);
    var out = "";
    var prev = null;
    for (var i = 0; i < blocks.length; i++) {
        var b = blocks[i];
        if (prev !== null && !_isBlockElement(prev) && !_isBlockElement(b))
            out += "<br>";
        if (b.gapBefore && !_isBlockElement(b) && (prev === null || !_isBlockElement(prev)))
            out += "<br>";
        out += _renderBlock(b, dialect, ctx);
        prev = b;
    }
    return out;
}

// plain: the text with its formatting taken off -- markers, fences, link
// targets -- for previews that have one line to say what a message is.
function plain(text, dialect) {
    var value = String(text || "");
    if (dialect !== "markdown" && dialect !== "whatsapp")
        return value;
    var ctx = { plain: true };
    return _blocks(value, dialect).map(function (b) {
        switch (b.type) {
        case "code":
            return b.lines.join("\n");
        case "heading":
            return _inline(b.text, dialect, ctx);
        case "rule":
            return "";
        case "quote":
            return b.lines.map(function (q) {
                return _inline(q.text, dialect, ctx);
            }).join("\n");
        case "list":
            return b.items.map(function (it) {
                return (it.ordered ? it.number + it.delim + " " : "• ") + _inline(it.text, dialect, ctx);
            }).join("\n");
        case "table":
            return [b.header].concat(b.rows).map(function (r) {
                return r.map(function (c) {
                    return _inline(c, dialect, ctx);
                }).join("  ");
            }).join("\n");
        default:
            return _inline(b.lines.join("\n"), dialect, ctx);
        }
    }).filter(function (s) {
        return s !== "";
    }).join("\n");
}
