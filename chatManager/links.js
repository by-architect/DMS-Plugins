.pragma library

// What a message may render, and what it may open.
//
// Message text is somebody else's input. It arrives from whoever wrote it, over
// a service that promises nothing about its contents, and two different things
// are then done with it: it is turned into markup, and parts of it are handed to
// whatever opens links. Both are places where the sender gets to decide
// something, so both are decided here instead of at each call.
//
// The shape of this -- escape everything, linkify by hand, and gate what may be
// opened on a single isWebUrl test -- follows DankChat's linkify.js (MIT), which
// had solved the same problem for the same reason. The bracket counting is its
// idea too.
//
// The rules are narrow on purpose. Everything is escaped before any markup is
// added, and only http and https are ever opened -- a link preview's target
// comes from the message as well, so "it is not text the user typed" is not a
// reason to trust it.

function escapeHtml(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// isWebUrl is the whole test for "may this be opened".
//
// Anchored, so nothing may be tacked on around it; no whitespace, so a second
// line cannot ride along; no quotes, so what is rendered cannot climb out of the
// attribute it sits in.
function isWebUrl(value) {
    return /^https?:\/\/[^\s<>"']+$/i.test(String(value));
}

// _trim takes the sentence back off a URL.
//
// A link at the end of a sentence collects the full stop, and one in brackets
// collects the closing bracket -- neither belongs to it, unless the URL opened
// that bracket itself, which is common enough in wiki links to be worth
// counting rather than guessing.
function _trim(url) {
    let out = url.replace(/[.,;:!?]+$/, "");
    const pairs = [["(", ")"], ["[", "]"]];
    for (let i = 0; i < pairs.length; i++) {
        const open = pairs[i][0];
        const close = pairs[i][1];
        while (out.endsWith(close) && out.split(close).length > out.split(open).length)
            out = out.slice(0, -1);
    }
    return out;
}

// render is the message body as markup: escaped, with its links clickable.
function render(value, color) {
    const text = String(value || "");
    const pattern = /https?:\/\/[^\s<>"']+/gi;

    let out = "";
    let at = 0;
    let match;

    while ((match = pattern.exec(text)) !== null) {
        const url = _trim(match[0]);
        out += escapeHtml(text.slice(at, match.index));
        out += "<a href=\"" + escapeHtml(url) + "\" style=\"color:" + escapeHtml(color) + "\">" + escapeHtml(url) + "</a>";
        at = match.index + url.length;
    }

    out += escapeHtml(text.slice(at));
    return out.replace(/\n/g, "<br>");
}

// firstWebUrl is the link a message is "about", or "" -- what a key that opens
// the selected message should act on.
function firstWebUrl(value) {
    const match = /https?:\/\/[^\s<>"']+/i.exec(String(value || ""));
    if (!match)
        return "";

    const url = _trim(match[0]);
    return isWebUrl(url) ? url : "";
}
