.pragma library
.import "util.js" as Util

// The "All machines" page: `matrix log <kind> --json`, which fans out over
// ssh to every host matrix knows and merges their records, newest first, one
// JSON object a line. Every kind shares one shape --
//
//   { host, date, epoch, service, command, status, name, source, target,
//     total, size, data, log, alert? }
//
// -- with status one of success, fail, warn or started. What a row says is
// worked out per kind here, as pure functions, so it runs and is tested
// outside the shell: `node tests/matrix.test.js`.

var KINDS = [
    {
        kind: "system",
        title: "System Errors",
        icon: "report"
    },
    {
        kind: "login",
        title: "Logins",
        icon: "login"
    },
    {
        kind: "boot",
        title: "Boots",
        icon: "restart_alt"
    },
    {
        kind: "build",
        title: "NixOS Builds",
        icon: "build"
    },
    {
        kind: "sync",
        title: "Sync & Backups",
        icon: "sync"
    },
    {
        kind: "file",
        title: "File Operations",
        icon: "folder_copy"
    },
    {
        kind: "network-device",
        title: "Network Devices",
        icon: "lan"
    },
    {
        kind: "logger",
        title: "Log Service",
        icon: "receipt_long"
    }
];

// --------------------------------------------------------------- reading

function recordMs(r) {
    var e = Number(r.epoch);
    if (isFinite(e) && e > 0)
        return e * 1000;
    var d = Date.parse(r.date || "");
    return isFinite(d) ? d : 0;
}

// One record a line; anything that is not a JSON object (a banner, a cut-off
// last line) is skipped. Each record gains `ms`, its time.
function parseRecords(text) {
    var out = [];
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line.charAt(0) !== "{")
            continue;
        var r;
        try {
            r = JSON.parse(line);
        } catch (e) {
            continue;
        }
        if (!r || typeof r !== "object")
            continue;
        r.ms = recordMs(r);
        r.host = r.host || "?";
        r.status = r.status || "";
        out.push(r);
    }
    return out;
}

// What matrix says on stderr about a host it could not reach:
// "mjolnir is unreachable — its sync records are left out".
function unreachableHosts(stderr) {
    var out = [];
    var lines = String(stderr || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var m = /^\s*(\S+) is unreachable/.exec(lines[i].replace(/\x1b\[[0-9;]*m/g, ""));
        if (m && out.indexOf(m[1]) < 0)
            out.push(m[1]);
    }
    return out;
}

// `data` is "key=value key=value", where a value may hold spaces (an SSID)
// or be quoted (unit="tmux-server.service"): a new pair starts only where a
// space is followed by a name and "=".
function parseData(data) {
    var out = {};
    if (!data)
        return out;
    var parts = String(data).split(/ (?=[A-Za-z_][A-Za-z0-9_]*=)/);
    for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf("=");
        if (eq <= 0)
            continue;
        var v = parts[i].substring(eq + 1);
        if (v.length >= 2 && v.charAt(0) === "\"" && v.charAt(v.length - 1) === "\"")
            v = v.substring(1, v.length - 1);
        out[parts[i].substring(0, eq)] = v;
    }
    return out;
}

function basename(p) {
    var s = String(p || "").replace(/\/+$/, "");
    var i = s.lastIndexOf("/");
    return i >= 0 ? s.substring(i + 1) : s;
}

var STATUS_WORDS = {
    success: "ok",
    fail: "failed",
    warn: "warning",
    started: "started"
};

function statusWord(status) {
    return STATUS_WORDS[status] || status || "";
}

// ------------------------------------------------------------- describing

// sshd and logind lines, said the short way; anything else as it came.
function loginSummary(msg) {
    var s = String(msg || "");
    var m;
    if ((m = /^Accepted (\S+) for (\S+) from (\S+)/.exec(s)))
        return m[2] + " · ssh " + m[1] + " from " + m[3];
    if ((m = /^Failed (\S+) for (?:invalid user )?(\S+) from (\S+)/.exec(s)))
        return "failed ssh " + m[1] + " for " + m[2] + " from " + m[3];
    if ((m = /^Invalid user (\S*) from (\S+)/.exec(s)))
        return "unknown user " + (m[1] || "(empty)") + " from " + m[2];
    if ((m = /^New session '?([^' ]+)'? of user '?([^' ]+)'?/.exec(s)))
        return m[2] + " · new session " + m[1];
    if ((m = /^Removed session '?([^' .]+)'?/.exec(s)))
        return "session " + m[1] + " ended";
    if ((m = /session opened for user ([^(\s]+)(?:\(uid=\d+\))?(?: by ([^(\s]*))?/.exec(s)))
        return m[1] + " · session opened" + (m[2] ? " by " + m[2] : "");
    if ((m = /session closed for user ([^(\s]+)/.exec(s)))
        return m[1] + " · session closed";
    if (/kex_exchange_identification/.test(s))
        return "ssh connection dropped before login";
    if ((m = /^Connection (?:closed|reset) by (?:authenticating user (\S+) )?(\S+) port/.exec(s)))
        return "connection closed by " + (m[1] ? m[1] + " at " : "") + m[2];
    if ((m = /^Disconnected from (?:user (\S+) )?(\S+) port/.exec(s)))
        return (m[1] ? m[1] + " · " : "") + "disconnected from " + m[2];
    return "";
}

// One record -> { primary, secondary, ms, key }. `key` is what makes two
// records the same thing happening again, so a tile shows it once with a
// count: the same error, the same device seen by every scan, the same file
// removed every quarter hour.
function describe(kind, r) {
    var d = parseData(r.data);
    var host = r.host;
    var out = {
        primary: "",
        secondary: "",
        ms: r.ms || 0,
        key: ""
    };
    switch (kind) {
    case "system":
        out.primary = r.command || r.service || "journal";
        out.secondary = r.log || "";
        out.key = [host, r.status, out.primary, out.secondary].join("\u001f");
        break;
    case "login":
        var said = loginSummary(r.log);
        out.primary = said || r.command || "login";
        out.secondary = said ? (r.command ? r.command + ": " : "") + (r.log || "") : (r.log || "");
        out.key = [host, r.status, r.command, r.log].join("\u001f");
        break;
    case "boot":
        var started = Date.parse(d.started || "");
        var ended = Date.parse(d.ended || "");
        var ran = isFinite(started) && isFinite(ended) && ended > started ? Util.fmtDuration((ended - started) / 1000) : "";
        out.primary = (r.status === "fail" ? "Unclean shutdown" : (r.status === "success" ? "Clean shutdown" : statusWord(r.status))) + (ran ? " · ran " + ran : "");
        out.secondary = isFinite(started) ? "started " + Util.fmtAbs(started) + (isFinite(ended) ? " · ended " + Util.fmtAbs(ended) : "") : (r.log || "");
        if (isFinite(ended))
            out.ms = ended;
        // The same boot is written again by every later logger run.
        out.key = [host, d.boot_id || r.data].join("\u001f");
        break;
    case "build":
        out.primary = d.generation ? "Generation " + d.generation : (r.command || "build");
        out.secondary = [d.version ? "NixOS " + d.version : "", r.service && r.service !== "security-manager" ? "by " + r.service : "", r.log || ""].filter(Boolean).join(" · ");
        out.key = [host, r.ms, d.generation].join("\u001f");
        break;
    case "sync":
        if (r.service === "syncthing") {
            // One row per folder: Syncthing reports every file it moves.
            out.primary = (r.name || "Syncthing") + " · " + (r.status === "success" ? "synced" : statusWord(r.status));
            out.secondary = r.source ? "last: " + r.source : (r.log || "");
            out.key = [host, r.service, r.name, r.status].join("\u001f");
        } else {
            out.primary = (r.name || r.service || "sync") + " · " + (r.command || "") + (r.status && r.status !== "success" ? " " + statusWord(r.status) : "");
            out.secondary = r.log || [r.source, r.target].filter(Boolean).join(" → ");
            out.key = [host, r.service, r.command, r.name, r.status, out.secondary].join("\u001f");
        }
        break;
    case "file":
        var what = r.name || basename(r.source) || r.target || "";
        var n = Number(r.total);
        out.primary = (r.command || "file") + " " + what + (n > 1 ? " +" + (n - 1) + " more" : "");
        // "Run by save.sh in tmux-server.service. Command: rm …" -- the
        // command itself is already the row's first line.
        var why = String(r.log || "").split(". Command:")[0];
        out.secondary = why || r.source || "";
        out.key = [host, r.command, r.source, r.target, r.status, why].join("\u001f");
        break;
    case "network-device":
        out.primary = [d.ip, d.mac].filter(Boolean).join("  ") || r.log || "device";
        out.secondary = [d.ssid && d.ssid !== "unknown" ? d.ssid : "", d.interface || ""].filter(Boolean).join(" · ");
        out.key = [host, d.mac, d.ip].join("\u001f");
        break;
    case "logger":
        out.primary = (r.name || "logger") + " · " + statusWord(r.status);
        out.secondary = r.log || r.target || r.data || "";
        out.key = [host, r.status, r.name, out.secondary].join("\u001f");
        break;
    default:
        out.primary = [r.service, r.command].filter(Boolean).join(" · ");
        out.secondary = r.log || r.data || "";
        out.key = [host, r.status, out.primary, out.secondary].join("\u001f");
    }
    return out;
}

// Records (newest first) -> rows, one per key, in order of each key's newest
// record: [{ host, status, primary, secondary, ms, count, alert }].
function group(kind, records, limit) {
    var out = [];
    var at = {};
    var max = limit > 0 ? limit : Infinity;
    for (var i = 0; i < records.length; i++) {
        var r = records[i];
        var d = describe(kind, r);
        var k = d.key;
        if (at[k] !== undefined) {
            var g = out[at[k]];
            g.count++;
            if (r.alert)
                g.alert = true;
            continue;
        }
        if (out.length >= max)
            continue;
        at[k] = out.length;
        out.push({
            host: r.host,
            status: r.status,
            primary: d.primary,
            secondary: d.secondary,
            ms: d.ms,
            count: 1,
            alert: !!r.alert
        });
    }
    return out;
}

function hostsOf(records) {
    var out = [];
    for (var i = 0; i < records.length; i++)
        if (out.indexOf(records[i].host) < 0)
            out.push(records[i].host);
    return out;
}

// The tile's verdict in its corner: { text, tone } with tone one of error,
// warning, success or neutral. `capped`: matrix stopped at the record limit,
// so a count of records is "at least" and says so with a "+".
function verdict(kind, records, rows, capped) {
    var more = capped ? "+" : "";
    var fails = 0;
    var warns = 0;
    for (var i = 0; i < records.length; i++) {
        if (records[i].status === "fail")
            fails++;
        else if (records[i].status === "warn")
            warns++;
    }
    var unclean = 0;
    for (var j = 0; j < rows.length; j++)
        if (rows[j].status === "fail")
            unclean++;
    switch (kind) {
    case "system":
        return fails > 0 ? {
            text: fails + more + (fails === 1 && !more ? " error" : " errors"),
            tone: "error"
        } : {
            text: "clean",
            tone: "success"
        };
    case "boot":
        return unclean > 0 ? {
            text: unclean + " unclean",
            tone: "error"
        } : {
            text: "all clean",
            tone: "success"
        };
    case "build":
        // Every build is its own row, but rows stop at the tile's limit.
        return {
            text: records.length + more + (records.length === 1 && !more ? " build" : " builds"),
            tone: fails > 0 ? "error" : "neutral"
        };
    case "network-device":
        return {
            text: rows.length + (rows.length === 1 ? " device" : " devices"),
            tone: "neutral"
        };
    case "file":
        if (fails === 0 && warns === 0)
            return {
                text: records.length + more + (records.length === 1 && !more ? " operation" : " operations"),
                tone: "neutral"
            };
        break;
    }
    if (fails > 0)
        return {
            text: fails + more + " failed",
            tone: "error"
        };
    if (warns > 0)
        return {
            text: warns + more + (warns === 1 && !more ? " warning" : " warnings"),
            tone: "warning"
        };
    return {
        text: records.length > 0 ? "all ok" : "",
        tone: "success"
    };
}
