.pragma library

// Shared parsing / formatting helpers for the system panel tiles.

function relTime(ms) {
    if (!ms || isNaN(ms))
        return "";
    var delta = Date.now() - ms;
    if (delta < 0)
        delta = 0;
    var s = Math.floor(delta / 1000);
    if (s < 45)
        return "just now";
    var m = Math.floor(s / 60);
    if (m < 60)
        return m + (m === 1 ? " minute ago" : " minutes ago");
    var h = Math.floor(m / 60);
    if (h < 24)
        return h + (h === 1 ? " hour ago" : " hours ago");
    var d = Math.floor(h / 24);
    if (d < 30)
        return d + (d === 1 ? " day ago" : " days ago");
    var mo = Math.floor(d / 30);
    if (mo < 12)
        return mo + (mo === 1 ? " month ago" : " months ago");
    var y = Math.floor(mo / 12);
    return y + (y === 1 ? " year ago" : " years ago");
}

function fmtDuration(seconds) {
    if (seconds === null || seconds === undefined || isNaN(seconds))
        return "";
    var s = Math.max(0, Math.floor(seconds));
    if (s < 60)
        return s + "s";
    var m = Math.floor(s / 60);
    if (m < 60)
        return m + "m";
    var h = Math.floor(m / 60);
    var rm = m % 60;
    if (h < 24)
        return rm > 0 ? (h + "h " + rm + "m") : (h + "h");
    var d = Math.floor(h / 24);
    var rh = h % 24;
    return rh > 0 ? (d + "d " + rh + "h") : (d + "d");
}

function fmtAbs(ms) {
    if (!ms || isNaN(ms))
        return "";
    var d = new Date(ms);
    function p(n) {
        return n < 10 ? "0" + n : "" + n;
    }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " + p(d.getHours()) + ":" + p(d.getMinutes());
}

// journalctl -o json emits newline-delimited JSON objects.
function parseNdjson(text) {
    var out = [];
    if (!text)
        return out;
    var lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line)
            continue;
        try {
            out.push(JSON.parse(line));
        } catch (e) {
        // journald occasionally emits non-JSON noise; skip it
        }
    }
    return out;
}

// journald __REALTIME_TIMESTAMP is microseconds since epoch, as a string.
function journalMs(entry) {
    var raw = entry.__REALTIME_TIMESTAMP || entry._SOURCE_REALTIME_TIMESTAMP;
    if (!raw)
        return 0;
    return Math.floor(parseInt(raw, 10) / 1000);
}

// journald MESSAGE can be a byte array when it is not valid UTF-8.
function journalMessage(entry) {
    var m = entry.MESSAGE;
    if (typeof m === "string")
        return m;
    if (Array.isArray(m)) {
        var s = "";
        for (var i = 0; i < m.length; i++)
            s += String.fromCharCode(m[i]);
        return s;
    }
    return "";
}

// Parses `loginctl show-session`-style output: KEY=VALUE lines, blocks
// separated by a blank line.
function parseKeyValueBlocks(text) {
    var blocks = [];
    if (!text)
        return blocks;
    var current = {};
    var has = false;
    var lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (!line.trim()) {
            if (has) {
                blocks.push(current);
                current = {};
                has = false;
            }
            continue;
        }
        var eq = line.indexOf("=");
        if (eq <= 0)
            continue;
        current[line.substring(0, eq)] = line.substring(eq + 1);
        has = true;
    }
    if (has)
        blocks.push(current);
    return blocks;
}

// systemd prints timestamps as "Sun 2026-08-16 09:28:45 +03".
function parseSystemdTimestamp(value) {
    if (!value)
        return 0;
    var m = value.match(/(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})/);
    if (!m)
        return 0;
    var t = Date.parse(m[1] + "T" + m[2]);
    return isNaN(t) ? 0 : t;
}

function parseIso(value) {
    if (!value)
        return 0;
    var t = Date.parse(value);
    return isNaN(t) ? 0 : t;
}

// Truncates a host/IP for display without losing the meaningful part.
function shortHost(host) {
    if (!host)
        return "";
    if (host.length <= 24)
        return host;
    return host.substring(0, 21) + "…";
}
