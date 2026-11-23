.pragma library

// Lighting up what the search inside a conversation (Ctrl+Shift+F) found.
//
// The search is the chat manager's (src/internal/chat/search.go): words in
// any order, part of a word, case and accents ignored, a typo forgiven. For
// each message it says what matched -- the words as that message writes them,
// "İstanbul" for "istanbul" -- and this finds those in the text a result row
// shows, comparing the way the manager does, so "İstanbul" is found however
// the preview spells it.

const _marks = /[̀-ͯ]/g;

// One character as a search compares it: lower case, no accent, the Turkish ı
// and İ both i, typographic quotes plain. Matches fold() in search.go, letter
// for letter where it matters.
function _foldChar(c) {
    switch (c) {
    case "ı":
    case "İ":
        return "i";
    case "ß":
        return "ss";
    case "æ":
    case "Æ":
        return "ae";
    case "œ":
    case "Œ":
        return "oe";
    case "ø":
    case "Ø":
        return "o";
    case "đ":
    case "Đ":
        return "d";
    case "ł":
    case "Ł":
        return "l";
    case "ħ":
    case "Ħ":
        return "h";
    case "ŧ":
    case "Ŧ":
        return "t";
    case "‘":
    case "’":
    case "‛":
    case "ʼ":
    case "´":
    case "′":
        return "'";
    case "“":
    case "”":
    case "„":
    case "‟":
    case "«":
    case "»":
    case "″":
        return "\"";
    }
    let d = c;
    try {
        d = c.normalize("NFD");
    } catch (e) {}
    return d.replace(_marks, "").toLowerCase();
}

// fold is text as a search compares it, with, for every character of that,
// where it came from: { text, at, source }. A run of spaces and line breaks
// is one space, as a phrase is matched.
function fold(text) {
    const s = String(text || "");
    let out = "";
    const at = [];
    let space = false;
    for (let i = 0; i < s.length;) {
        const ch = String.fromCodePoint(s.codePointAt(i));
        if (/\s/.test(ch)) {
            if (!space) {
                out += " ";
                at.push(i);
            }
            space = true;
        } else {
            space = false;
            const f = _foldChar(ch);
            for (let k = 0; k < f.length; k++) {
                out += f[k];
                at.push(i);
            }
        }
        i += ch.length;
    }
    return {
        "text": out,
        "at": at,
        "source": s
    };
}

// Where the folded text's character before j ends in the source, accents
// written after it included.
function _end(f, j) {
    const start = f.at[j - 1];
    let end = start + String.fromCodePoint(f.source.codePointAt(start)).length;
    while (end < f.source.length && /[̀-ͯ]/.test(f.source.charAt(end)))
        end++;
    return end;
}

// ranges is every place in text that one of marks is, as [start, end) in
// text's own positions, in order, overlapping ones joined.
function ranges(text, marks) {
    const f = fold(text);
    const found = [];
    const list = marks || [];
    for (let m = 0; m < list.length; m++) {
        const mark = fold(list[m]).text.trim();
        if (mark === "")
            continue;
        for (let i = f.text.indexOf(mark); i >= 0; i = f.text.indexOf(mark, i + mark.length))
            found.push([f.at[i], _end(f, i + mark.length)]);
    }
    found.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    const out = [];
    for (let i = 0; i < found.length; i++) {
        const last = out.length > 0 ? out[out.length - 1] : null;
        if (last && found[i][0] <= last[1])
            last[1] = Math.max(last[1], found[i][1]);
        else
            out.push(found[i].slice());
    }
    return out;
}

function escape(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function _isLow(s, i) {
    const c = s.charCodeAt(i);
    return c >= 0xdc00 && c <= 0xdfff;
}

// snippet is text for a result row, as StyledText: a stretch of it around the
// first match, with every match in it drawn in color, everything escaped --
// it is somebody else's message. `before` characters lead up to the match,
// and the stretch is `length` long, or longer when the match is.
function snippet(text, spans, color, before, length) {
    const s = String(text || "");
    if (!spans || spans.length === 0)
        return escape(s.length > length ? s.slice(0, length) + "…" : s);
    let from = Math.max(0, spans[0][0] - before);
    let to = Math.min(s.length, Math.max(from + length, spans[0][1]));
    // Never half an emoji at either end.
    if (from > 0 && _isLow(s, from))
        from--;
    if (to < s.length && _isLow(s, to))
        to++;
    let out = from > 0 ? "…" : "";
    let pos = from;
    for (let i = 0; i < spans.length && spans[i][0] < to; i++) {
        const start = Math.max(spans[i][0], pos);
        const end = Math.min(spans[i][1], to);
        if (end <= start)
            continue;
        out += escape(s.slice(pos, start)) + "<b><font color=\"" + color + "\">" + escape(s.slice(start, end)) + "</font></b>";
        pos = end;
    }
    return out + escape(s.slice(pos, to)) + (to < s.length ? "…" : "");
}
