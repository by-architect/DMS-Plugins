.pragma library

.import "emojidata.js" as Data

// Finding an emoji by name.
//
// Typing an emoji is the hard part on a desktop: there is no emoji key, and
// the reaction box asked for one to be typed in. So emoji are found the way
// chat apps find them -- by any word of their name, their :shortcode: or a tag
// ("happy", "lol") -- and a finished :shortcode: in a message turns into its
// emoji, the way Slack, Element and GitHub do it.

var categories = Data.categories;

var _flat = null;
var _byCode = null;

// Every emoji once, in the order of the categories, as
// { emoji, name, codes: [..], words: [..] }.
function all() {
    if (_flat)
        return _flat;
    _flat = [];
    _byCode = {};
    for (var c = 0; c < categories.length; c++) {
        var list = categories[c].emoji;
        for (var i = 0; i < list.length; i++) {
            var e = list[i];
            var item = {
                "emoji": e[0],
                "name": e[1],
                "codes": e[2] ? e[2].split(" ") : [],
                "words": (e[1] + " " + e[3]).toLowerCase().split(/[\s:_-]+/).filter(function (w) {
                    return w !== "";
                })
            };
            _flat.push(item);
            for (var k = 0; k < item.codes.length; k++)
                _byCode[item.codes[k]] = item.emoji;
        }
    }
    return _flat;
}

// The emoji a shortcode stands for -- "thumbsup" or ":thumbsup:" -- or "".
function fromShortcode(code) {
    all();
    var key = String(code || "").toLowerCase().replace(/^:|:$/g, "");
    return _byCode[key] || "";
}

// The name an emoji goes by, for a tooltip: its first shortcode, else its
// description.
function nameOf(emoji) {
    var list = all();
    for (var i = 0; i < list.length; i++) {
        if (list[i].emoji === emoji)
            return list[i].codes.length > 0 ? ":" + list[i].codes[0] + ":" : list[i].name;
    }
    return "";
}

// The emoji whose names match a query, best first: a shortcode that is the
// query, then one that starts with it, then a word of the name or a tag that
// starts with it, then anything containing it. Every word of a query of
// several has to match ("red heart").
function search(query, limit) {
    var words = String(query || "").toLowerCase().replace(/^:|:$/g, "").split(/[\s_]+/).filter(function (w) {
        return w !== "";
    });
    var max = limit || 64;
    if (words.length === 0)
        return [];

    var scored = [];
    var list = all();
    for (var i = 0; i < list.length; i++) {
        var item = list[i];
        var total = 0;
        var ok = true;
        for (var w = 0; w < words.length && ok; w++) {
            var s = _score(item, words[w], words.length === 1 ? words[w] : words.join("_"));
            if (s < 0)
                ok = false;
            else
                total += s;
        }
        if (ok)
            scored.push({
                "emoji": item.emoji,
                "score": total,
                "at": i
            });
    }
    scored.sort(function (a, b) {
        return a.score - b.score || a.at - b.at;
    });
    return scored.slice(0, max).map(function (s) {
        return s.emoji;
    });
}

function _score(item, word, whole) {
    var best = -1;
    for (var c = 0; c < item.codes.length; c++) {
        var code = item.codes[c];
        if (code === whole || code === word)
            return 0;
        if (code.indexOf(word) === 0)
            best = 1;
    }
    if (best >= 0)
        return best;
    for (var w = 0; w < item.words.length; w++) {
        if (item.words[w] === word)
            return 2;
        if (item.words[w].indexOf(word) === 0)
            best = 3;
    }
    if (best >= 0)
        return best;
    // Only for something long enough to mean it: "a" is in half the names.
    if (word.length >= 3 && item.name.toLowerCase().indexOf(word) !== -1)
        return 4;
    return -1;
}

// A :shortcode: just finished at the cursor, turned into its emoji.
//
// Returns { text, cursor } with the shortcode replaced, or null when the text
// before the cursor does not end in a known one -- so "at 10:30:" and a
// half-typed ":thumbs" are left as they are.
function replaceShortcodeAt(text, cursor) {
    var before = String(text).slice(0, cursor);
    var m = /(^|[\s(\[{"'])(:[a-z0-9_+\-]{2,}:)$/i.exec(before);
    if (!m)
        return null;
    var emoji = fromShortcode(m[2]);
    if (!emoji)
        return null;
    var start = before.length - m[2].length;
    return {
        "text": before.slice(0, start) + emoji + String(text).slice(cursor),
        "cursor": start + emoji.length
    };
}

// What a typed reaction comes to: a shortcode or a name is looked up, and
// anything else -- an emoji typed or pasted, a word a service accepts as a
// reaction -- is kept as it is.
function resolve(typed) {
    var t = String(typed || "").trim();
    if (t === "")
        return "";
    if (/^[a-z0-9_:+\-\s]+$/i.test(t)) {
        var found = fromShortcode(t) || search(t, 1)[0];
        if (found)
            return found;
    }
    return t;
}
