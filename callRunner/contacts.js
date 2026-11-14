.pragma library

// Call Runner's book: what scripts/phone.sh says about the phone's contacts
// and calls, and what typing a name or a number finds in it. No QML here, so
// tests/tst_contacts.qml can check all of it.

// A number's kind, as Android keeps it (Phone.TYPE_*, data2).
var KINDS = {
    "1": "home",
    "2": "mobile",
    "3": "work",
    "4": "work fax",
    "5": "home fax",
    "6": "pager",
    "7": "other",
    "8": "callback",
    "9": "car",
    "10": "company",
    "11": "ISDN",
    "12": "main",
    "13": "other fax",
    "14": "radio",
    "15": "telex",
    "16": "TTY",
    "17": "work mobile",
    "18": "work pager",
    "19": "assistant",
    "20": "MMS"
};

// A call's type (CallLog.Calls.TYPE): its word and its icon.
var CALLS = {
    "1": ["incoming", "call_received"],
    "2": ["outgoing", "call_made"],
    "3": ["missed", "call_missed"],
    "4": ["voicemail", "voicemail"],
    "5": ["rejected", "call_end"],
    "6": ["blocked", "block"],
    "7": ["answered elsewhere", "call_received"]
};

function _null(v) {
    var s = String(v === undefined || v === null ? "" : v).trim();
    return s === "NULL" ? "" : s;
}

// Only what a dialer takes: digits, * and #, and + in front.
function dialable(text) {
    var s = String(text || "").replace(/[^0-9+*#]/g, "");
    return s.charAt(0) === "+" ? "+" + s.slice(1).replace(/\+/g, "") : s.replace(/\+/g, "");
}

// The last ten digits: the same person's number written +90 555 …, 0555 …
// or 555 … is one key.
function numberKey(number) {
    var d = String(number || "").replace(/\D/g, "");
    return d.length > 10 ? d.slice(-10) : d;
}

// For matching what is typed: lower case, without accents, and Turkish's
// dotless ı as i -- "sukru" finds Şükrü, "isik" finds Işık.
function fold(text) {
    var s = String(text || "").toLowerCase();
    if (typeof s.normalize === "function")
        s = s.normalize("NFD");
    return s.replace(/[̀-ͯ]/g, "").replace(/ı/g, "i");
}

// phone.sh's output -> { serial, contacts, calls, state, ok, error, via }
//   contacts [{ id, name, number, kind, starred, key }], one per person and
//            number, by name
//   calls    [{ date, type, duration, number, name, key }], newest first
function parse(text) {
    var out = {
        serial: "",
        contacts: [],
        calls: [],
        state: -1,
        ok: "",
        error: "",
        via: "ssh"
    };
    var seen = {};
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/\r$/, "");
        if (line.indexOf("cr:") !== 0)
            continue;
        var sp = line.indexOf(" ");
        var tag = sp < 0 ? line.slice(3) : line.slice(3, sp);
        var rest = sp < 0 ? "" : line.slice(sp + 1);
        var m;
        switch (tag) {
        case "serial":
            out.serial = rest.trim();
            break;
        case "c":
            // display_name last: it may hold ", ".
            m = /^contact_id=([^,]*), starred=([^,]*), data2=([^,]*), data1=(.*?), display_name=(.*)$/.exec(rest);
            if (!m)
                break;
            var number = _null(m[4]);
            if (dialable(number) === "")
                break;
            var c = {
                id: _null(m[1]),
                name: _null(m[5]) || number,
                number: number,
                kind: KINDS[_null(m[3])] || "",
                starred: _null(m[2]) === "1",
                key: numberKey(number)
            };
            // One person's number, saved in two accounts, is one row.
            var k = c.id + "|" + c.key;
            if (seen[k] !== undefined) {
                var prev = out.contacts[seen[k]];
                prev.starred = prev.starred || c.starred;
                prev.kind = prev.kind || c.kind;
                break;
            }
            seen[k] = out.contacts.length;
            out.contacts.push(c);
            break;
        case "r":
            m = /^date=(\d+), type=(\d+), duration=(\d+), number=(.*?), name=(.*)$/.exec(rest);
            if (m)
                out.calls.push({
                    date: Number(m[1]),
                    type: Number(m[2]),
                    duration: Number(m[3]),
                    number: _null(m[4]),
                    name: _null(m[5]),
                    key: numberKey(m[4])
                });
            break;
        case "state":
            out.state = /^\d$/.test(rest.trim()) ? Number(rest.trim()) : -1;
            break;
        case "ok":
            out.ok = rest.trim();
            break;
        case "error":
            out.error = rest.trim();
            break;
        case "via":
            out.via = rest.trim();
            break;
        }
    }
    out.contacts.sort(function (a, b) {
        return fold(a.name) < fold(b.name) ? -1 : (fold(a.name) > fold(b.name) ? 1 : 0);
    });
    out.calls.sort(function (a, b) {
        return b.date - a.date;
    });
    return out;
}

// "2 h ago", "3 d ago", "now".
function agoText(ms, nowMs) {
    var s = Math.max(0, Math.round((nowMs - ms) / 1000));
    if (s < 60)
        return "now";
    if (s < 3600)
        return Math.floor(s / 60) + " min ago";
    if (s < 86400)
        return Math.floor(s / 3600) + " h ago";
    if (s < 86400 * 30)
        return Math.floor(s / 86400) + " d ago";
    return Math.floor(s / (86400 * 30)) + " mo ago";
}

function callWord(type) {
    return (CALLS[String(type)] || ["call", "call"])[0];
}

function callIcon(type) {
    return (CALLS[String(type)] || ["call", "call"])[1];
}

// How well a person matches what is typed; 0 is not at all. A name that
// starts with it beats one with a word that does, which beats one holding it
// somewhere. Several words each start one of the name's words ("ali y" finds
// Ali Yılmaz). Three digits or more also look in the number.
function score(entry, query) {
    var q = fold(query).trim();
    if (q === "")
        return 1;
    var name = fold(entry.name);
    var words = name.split(/[\s,.\-()]+/).filter(function (w) {
        return w !== "";
    });
    var best = 0;
    if (name === q)
        best = 100;
    else if (name.indexOf(q) === 0)
        best = 90;
    else if (words.some(function (w) {
        return w.indexOf(q) === 0;
    }))
        best = 80;
    else {
        var parts = q.split(/\s+/);
        var all = parts.length > 1 && parts.every(function (p) {
            return words.some(function (w) {
                return w.indexOf(p) === 0;
            });
        });
        if (all)
            best = 70;
        else if (q.length >= 2 && name.indexOf(q) >= 0)
            best = 50;
    }
    var digits = String(query).replace(/\D/g, "");
    if (digits.length >= 3 && /^[\d\s+()\-]+$/.test(String(query).trim())) {
        var nd = String(entry.number).replace(/\D/g, "");
        if (numberKey(digits) === entry.key && entry.key !== "")
            best = Math.max(best, 95);
        else if (nd.indexOf(digits) >= 0 || nd.indexOf(digits.replace(/^0+/, "")) >= 0)
            best = Math.max(best, 60);
    }
    return best;
}

// Whether what is typed is a number to call as it is.
function looksLikeNumber(query) {
    var q = String(query || "").trim();
    return /^[\d\s+()\-*#]+$/.test(q) && q.replace(/\D/g, "").length >= 3;
}

// The rows for what is typed, best first: [{ name, who, number, kind,
// comment, icon, score }] -- who is the name a toast says it calls. Nothing typed: the newest calls (one row per number), then
// the starred, then everybody by name. A typed number is also a row of its
// own, to call it as typed.
//   opts: { max, recent, nowMs }
function rows(book, query, opts) {
    var o = opts || {};
    var max = o.max || 40;
    var nowMs = o.nowMs || Date.now();
    var contacts = book && book.contacts ? book.contacts : [];
    var calls = book && book.calls ? book.calls : [];
    var byKey = {};
    for (var i = 0; i < contacts.length; i++)
        if (byKey[contacts[i].key] === undefined)
            byKey[contacts[i].key] = contacts[i];
    var lastCall = {};
    for (var j = 0; j < calls.length; j++)
        if (calls[j].key !== "" && lastCall[calls[j].key] === undefined)
            lastCall[calls[j].key] = calls[j];

    function lastText(key) {
        var c = lastCall[key];
        return c ? callWord(c.type) + " " + agoText(c.date, nowMs) : "";
    }
    function contactRow(c, sc) {
        return {
            name: c.name,
            who: c.name,
            number: c.number,
            kind: c.kind,
            comment: [c.kind, c.number, lastText(c.key)].filter(function (x) {
                return x !== "";
            }).join("  ·  "),
            icon: c.starred ? "star" : "person",
            score: sc
        };
    }

    var out = [];
    var shown = {};
    var q = String(query || "").trim();

    if (q === "") {
        var recent = o.recent === undefined ? 10 : o.recent;
        for (var r = 0; r < calls.length && out.length < recent; r++) {
            var call = calls[r];
            if (dialable(call.number) === "" || shown[call.key])
                continue;
            shown[call.key] = true;
            var who = byKey[call.key];
            out.push({
                name: who ? who.name : (call.name || call.number),
                who: who ? who.name : (call.name || call.number),
                number: call.number,
                kind: who ? who.kind : "",
                comment: [callWord(call.type) + " " + agoText(call.date, nowMs), who && who.kind ? who.kind : "", call.number].filter(function (x) {
                    return x !== "";
                }).join("  ·  "),
                icon: callIcon(call.type),
                score: 1
            });
        }
        var starred = contacts.filter(function (c) {
            return c.starred;
        });
        var rest = contacts.filter(function (c) {
            return !c.starred;
        });
        var more = starred.concat(rest);
        for (var s = 0; s < more.length && out.length < max; s++) {
            if (shown[more[s].key])
                continue;
            shown[more[s].key] = true;
            out.push(contactRow(more[s], 1));
        }
        return out;
    }

    if (looksLikeNumber(q)) {
        var typed = dialable(q);
        var known = byKey[numberKey(typed)];
        out.push({
            name: "Call " + typed,
            who: known ? known.name : typed,
            number: typed,
            kind: "",
            comment: known ? known.name + (known.kind ? "  ·  " + known.kind : "") : "the number as typed",
            icon: "dialpad",
            score: 1000
        });
    }

    var found = [];
    for (var f = 0; f < contacts.length; f++) {
        var sc = score(contacts[f], q);
        if (sc > 0)
            found.push(contactRow(contacts[f], sc));
    }
    // Callers not in the contacts, found by their number or the name the
    // network gave.
    var strangers = {};
    for (var g = 0; g < calls.length; g++) {
        var cl = calls[g];
        if (byKey[cl.key] || strangers[cl.key] || dialable(cl.number) === "")
            continue;
        var ssc = score({
            name: cl.name || "",
            number: cl.number,
            key: cl.key
        }, q);
        if (ssc > 0) {
            strangers[cl.key] = true;
            found.push({
                name: cl.name || cl.number,
                who: cl.name || cl.number,
                number: cl.number,
                kind: "",
                comment: [callWord(cl.type) + " " + agoText(cl.date, nowMs), cl.number].join("  ·  "),
                icon: callIcon(cl.type),
                score: ssc
            });
        }
    }
    // Best match first, then the one called last, then by name.
    found.sort(function (a, b) {
        if (a.score !== b.score)
            return b.score - a.score;
        var ca = lastCall[numberKey(a.number)];
        var cb = lastCall[numberKey(b.number)];
        var da = ca ? ca.date : 0;
        var db = cb ? cb.date : 0;
        if (da !== db)
            return db - da;
        return fold(a.name) < fold(b.name) ? -1 : (fold(a.name) > fold(b.name) ? 1 : 0);
    });
    for (var h = 0; h < found.length && out.length < max; h++)
        out.push(found[h]);
    return out;
}
