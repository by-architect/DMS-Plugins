.pragma library

// Pure helpers for turning one status file into one row. Everything here is
// side-effect free so it can be exercised outside quickshell (node actions.js
// style) and so the QML above it stays layout-only.

// The collector script prints this before every file it cats, followed by the
// file's own name and a newline. Splitting on it is what keeps one unparsable
// file from poisoning the rest of the dump.
var MARK = "\n===dejavu===";

function parseDump(raw) {
    var out = [];
    if (!raw)
        return out;
    var chunks = raw.split(MARK);
    for (var i = 1; i < chunks.length; i++) {
        var c = chunks[i];
        var nl = c.indexOf("\n");
        if (nl < 0)
            continue;
        var body = c.slice(nl + 1);
        var data = null;
        try {
            data = JSON.parse(body);
        } catch (e) {
            // A file caught halfway through a write parses as nothing. The
            // caller keeps the previous snapshot of that action rather than
            // blinking the row out and back.
            data = null;
        }
        out.push({
            file: c.slice(0, nl),
            body: body,
            data: data
        });
    }
    return out;
}

var FAILED_WORDS = ["fail", "error", "abort", "cancel", "denied", "refused", "timeout"];
var ACTIVE_WORDS = ["run", "active", "progress", "copy", "mov", "sync", "work", "busy", "pend", "queue", "paus", "start"];
var DONE_WORDS = ["done", "complete", "finish", "success", "ok", "closed"];

function phaseOf(status) {
    var s = String(status === undefined || status === null ? "" : status).toLowerCase().trim();
    if (!s)
        return "active";
    var i;
    for (i = 0; i < FAILED_WORDS.length; i++)
        if (s.indexOf(FAILED_WORDS[i]) >= 0)
            return "failed";
    for (i = 0; i < DONE_WORDS.length; i++)
        if (s.indexOf(DONE_WORDS[i]) >= 0)
            return "done";
    for (i = 0; i < ACTIVE_WORDS.length; i++)
        if (s.indexOf(ACTIVE_WORDS[i]) >= 0)
            return "active";
    // An unknown word on a file that still exists is far more likely to be a
    // state this plugin has not seen yet than a finished action.
    return "active";
}

function isPaused(status) {
    return String(status || "").toLowerCase().indexOf("paus") >= 0;
}

function num(v) {
    if (typeof v === "number")
        return isFinite(v) ? v : NaN;
    if (typeof v !== "string")
        return NaN;
    var s = v.trim().replace(",", ".");
    if (!s)
        return NaN;
    var n = parseFloat(s);
    return isFinite(n) ? n : NaN;
}

function str(v) {
    return v === undefined || v === null ? "" : String(v);
}

function pick(d) {
    for (var i = 1; i < arguments.length; i++) {
        var k = arguments[i];
        if (d[k] !== undefined && d[k] !== null && d[k] !== "")
            return d[k];
    }
    return undefined;
}

function timeMs(v) {
    if (v === undefined || v === null || v === "")
        return NaN;
    // Seconds or milliseconds since the epoch, both of which show up in status
    // files, and the event log writes its `epoch` as a string of digits.
    if (typeof v === "number")
        return v > 1e11 ? v : v * 1000;
    if (/^\d+$/.test(String(v).trim())) {
        var n = parseInt(String(v).trim(), 10);
        return n > 1e11 ? n : n * 1000;
    }
    var t = Date.parse(String(v));
    return isFinite(t) ? t : NaN;
}

// "0:00:18" / "1:02:03" / 18 / "18s" all mean the same thing to a person.
function etaText(v) {
    if (v === undefined || v === null || v === "")
        return "";
    if (typeof v === "number")
        return durationText(v);
    var s = String(v).trim();
    var m = s.match(/^(\d+):(\d{2})(?::(\d{2}))?$/);
    if (!m)
        return s;
    var secs = m[3] !== undefined ? (+m[1]) * 3600 + (+m[2]) * 60 + (+m[3]) : (+m[1]) * 60 + (+m[2]);
    return durationText(secs);
}

function durationText(secs) {
    if (!isFinite(secs) || secs < 0)
        return "";
    secs = Math.round(secs);
    if (secs < 60)
        return secs + "s";
    var m = Math.floor(secs / 60);
    var s = secs % 60;
    if (m < 60)
        return s ? m + "m " + s + "s" : m + "m";
    var h = Math.floor(m / 60);
    m = m % 60;
    return m ? h + "h " + m + "m" : h + "h";
}

function bytesText(n) {
    if (!isFinite(n) || n < 0)
        return "";
    var units = ["B", "KB", "MB", "GB", "TB", "PB"];
    var i = 0;
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    var digits = i === 0 ? 0 : (n < 10 ? 2 : (n < 100 ? 1 : 0));
    return n.toFixed(digits) + " " + units[i];
}

// Always rounds down: a copy at 99.7% that reads "100%" looks finished when
// it is not, and the last percent is exactly the one people wait on.
function percentText(p) {
    if (!isFinite(p) || p < 0)
        return "";
    if (p >= 100)
        return "100%";
    if (p < 10)
        return (Math.floor(p * 10) / 10).toFixed(1) + "%";
    return Math.floor(p) + "%";
}

function relTime(ms, nowMs) {
    if (!isFinite(ms))
        return "";
    var d = Math.max(0, (nowMs || Date.now()) - ms);
    var s = Math.floor(d / 1000);
    if (s < 45)
        return "just now";
    var m = Math.floor(s / 60);
    if (m < 60)
        return m + "m ago";
    var h = Math.floor(m / 60);
    if (h < 24)
        return h + "h ago";
    var day = Math.floor(h / 24);
    return day + "d ago";
}

// Status files name files the way they were given them, which for a cache
// directory means percent-encoded paths that are unreadable in a 400px popout.
function decodePath(p) {
    if (!p || p.indexOf("%") < 0)
        return p;
    try {
        return decodeURIComponent(p);
    } catch (e) {
        return p;
    }
}

function baseName(p) {
    var s = decodePath(String(p || "")).replace(/\/+$/, "");
    if (!s)
        return "";
    var i = s.lastIndexOf("/");
    return i < 0 ? s : s.slice(i + 1);
}

// The wrappers that write these records: cp, mv, rm, rsync, scp, curl, wget,
// aria2c, torrent, git-clone, trash-restore, trash-empty. Anything else still
// gets a row, with the generic icon.
var ICONS = [
    [/^(cp|copy|install)$/, "content_copy"],
    [/^(mv|move|rename)$/, "drive_file_move"],
    [/^(rm|rmdir|delete|shred)$/, "delete"],
    [/^trash-empty$/, "delete_forever"],
    [/^trash-restore$/, "restore_from_trash"],
    [/^(rsync|sync|unison)$/, "sync"],
    [/^(scp|sftp|ftp|upload)$/, "cloud_upload"],
    [/^(wget|curl|aria2c?|yt-dlp|youtube-dl|download)$/, "download"],
    [/^torrent$/, "download_for_offline"],
    [/^git(-clone)?$/, "commit"],
    [/^(tar|zip|unzip|gzip|gunzip|7z|xz|zstd|bzip2|compress|extract)$/, "folder_zip"],
    [/^(dd|mkfs|flash|burn)$/, "save"],
    [/^(mkdir|touch|create)$/, "create_new_folder"],
    [/^(chmod|chown|setfacl)$/, "key"]
];

function iconFor(command) {
    var c = String(command || "").toLowerCase().trim();
    for (var i = 0; i < ICONS.length; i++)
        if (ICONS[i][0].test(c))
            return ICONS[i][1];
    return "bolt";
}

function normalize(file, d, nowMs) {
    d = d || {};
    var status = str(pick(d, "status", "state"));
    var phase = phaseOf(status);
    var done = num(pick(d, "bytes_done", "done", "transferred"));
    var total = num(pick(d, "bytes_total", "total", "size"));
    var pct = num(pick(d, "percent", "percentage", "progress"));
    if (!isFinite(pct) || pct < 0)
        pct = (isFinite(done) && isFinite(total) && total > 0) ? (done / total) * 100 : -1;
    if (pct > 100)
        pct = 100;

    return {
        key: file,
        file: file,
        id: str(pick(d, "id")),
        pid: num(pick(d, "pid")),
        command: str(pick(d, "command", "action", "op")) || "action",
        status: status || (phase === "active" ? "running" : ""),
        phase: phase,
        paused: isPaused(status),
        percent: pct,
        bytesDone: done,
        bytesTotal: total,
        rate: str(pick(d, "rate", "speed")),
        eta: etaText(pick(d, "eta", "remaining")),
        currentFile: str(pick(d, "current_file", "current", "file")),
        source: str(pick(d, "source", "src", "from")),
        target: str(pick(d, "target", "dest", "destination", "to")),
        startedMs: timeMs(pick(d, "started", "start", "started_at", "begin")),
        endedMs: timeMs(pick(d, "finished", "ended", "completed", "finished_at", "ended_at", "end")),
        error: str(pick(d, "error", "message", "reason")),
        stale: false
    };
}

// "cp  .cache → newcache" — the two names that answer "what is this?" without
// spending the whole row on paths that share a prefix anyway.
function titleOf(a) {
    var src = baseName(a.source);
    var dst = baseName(a.target);
    // A trashed file's target is the same name inside the trash, and
    // "newcache → newcache" says nothing twice.
    if (src && dst && src !== dst)
        return src + " → " + dst;
    return src || dst || baseName(a.name) || a.command;
}

// A zero rate and "0s left" are what the first second of a transfer looks
// like before the writer has anything to report, and they read as a stall.
// Nothing is better than a wrong number here.
function isZeroish(v) {
    return !v || /^0([.,]0*)?\s*[kmgtp]?b(\/s|ps)?$/i.test(String(v).trim()) || /^0+s$/.test(String(v).trim());
}

function subtitleOf(a) {
    var parts = [];
    if (isFinite(a.bytesDone) && isFinite(a.bytesTotal) && a.bytesTotal > 0)
        parts.push(bytesText(a.bytesDone) + " of " + bytesText(a.bytesTotal));
    else if (isFinite(a.bytesDone) && a.bytesDone > 0)
        parts.push(bytesText(a.bytesDone));
    if (a.rate && !isZeroish(a.rate))
        parts.push(a.rate);
    if (a.eta && !isZeroish(a.eta))
        parts.push(a.eta + " left");
    return parts.join(" · ");
}

function doneSubtitleOf(a) {
    var parts = [];
    if (a.phase === "failed" && a.error)
        parts.push(a.error);
    else {
        if (isFinite(a.files) && a.files > 0)
            parts.push(a.files === 1 ? "1 file" : a.files + " files");
        if (isFinite(a.bytesTotal) && a.bytesTotal > 0)
            parts.push(bytesText(a.bytesTotal));
        else if (isFinite(a.bytesDone) && a.bytesDone > 0)
            parts.push(bytesText(a.bytesDone));
    }
    if (isFinite(a.startedMs) && isFinite(a.endedMs) && a.endedMs > a.startedMs)
        parts.push("in " + durationText((a.endedMs - a.startedMs) / 1000));
    if (a.phase === "ended" && isFinite(a.percent) && a.percent >= 0)
        parts.push("stopped at " + percentText(a.percent));
    return parts.join(" · ");
}

// ---------------------------------------------------------------- ingestion
//
// One poll in, the whole visible state out. This is the part with the actual
// rules in it — what counts as still running, when a finished action enters
// the history and what to say about one whose file simply disappeared — so it
// lives here as a pure function over the previous snapshot rather than inside
// the QML.
//
// prevSeen maps file name -> { raw, lastChangeMs, phase, endedMs, action }.
function ingest(prevSeen, prevHistory, raw, opts) {
    opts = opts || {};
    var now = opts.nowMs || Date.now();
    var staleMs = opts.staleMs === undefined ? 45000 : opts.staleMs;
    var limit = opts.historyLimit === undefined ? 20 : opts.historyLimit;

    var seen = prevSeen || {};
    var entries = parseDump(raw);
    var nextSeen = {};
    var active = [];
    var finished = [];
    var i;

    for (i = 0; i < entries.length; i++) {
        var entry = entries[i];
        var prev = seen[entry.file];

        // A file caught halfway through a write parses as nothing: keep
        // showing what it last said instead of blinking the row out.
        var action = entry.data ? normalize(entry.file, entry.data, now) : (prev ? prev.action : null);
        if (!action)
            continue;

        var body = entry.data ? entry.body : (prev ? prev.raw : "");
        var changed = !prev || prev.raw !== body;
        var lastChangeMs = changed ? now : prev.lastChangeMs;

        if (action.phase === "active") {
            // Nothing in the file says whether its writer is still alive, so
            // one that has stopped changing is flagged rather than left
            // sitting at 94% forever.
            action.stale = (now - lastChangeMs) > staleMs;
            active.push(action);
            nextSeen[entry.file] = {
                raw: body,
                lastChangeMs: lastChangeMs,
                phase: "active",
                endedMs: NaN,
                action: action
            };
            continue;
        }

        // Terminal, with the file still in place. Remember when we first saw
        // it end so the row does not creep forward on every poll.
        var endedMs = isFinite(action.endedMs) ? action.endedMs : (prev && isFinite(prev.endedMs) ? prev.endedMs : lastChangeMs);
        action.endedMs = endedMs;
        if (changed || !prev || prev.phase === "active")
            finished.push(action);
        nextSeen[entry.file] = {
            raw: body,
            lastChangeMs: lastChangeMs,
            phase: action.phase,
            endedMs: endedMs,
            action: action
        };
    }

    // Files that vanished. One that was still running told us nothing about
    // how it went, so it is reported as ended rather than done — unless it was
    // all but complete, which is the ordinary case of a writer cleaning up
    // after itself.
    for (var key in seen) {
        if (nextSeen[key] !== undefined)
            continue;
        var gone = seen[key];
        if (gone.phase !== "active")
            continue;
        var ended = {};
        for (var f in gone.action)
            ended[f] = gone.action[f];
        ended.phase = (isFinite(ended.percent) && ended.percent >= 99.5) ? "done" : "ended";
        ended.status = ended.phase === "done" ? "completed" : "ended";
        ended.endedMs = now;
        ended.stale = false;
        finished.push(ended);
    }

    active.sort(function (a, b) {
        return (isFinite(b.startedMs) ? b.startedMs : 0) - (isFinite(a.startedMs) ? a.startedMs : 0);
    });

    return {
        dirPresent: String(raw || "").indexOf("dir:missing") !== 0,
        active: active,
        seen: nextSeen,
        history: finished.length > 0 ? mergeHistory(prevHistory || [], finished, limit) : (prevHistory || []),
        historyChanged: finished.length > 0
    };
}

// An action whose file is rewritten under the same name replaces its own row
// instead of stacking duplicates.
function mergeHistory(history, finished, limit) {
    var replaced = {};
    var merged = [];
    var i;

    for (i = 0; i < finished.length; i++) {
        replaced[finished[i].key] = true;
        merged.push(finished[i]);
    }
    for (i = 0; i < history.length; i++) {
        if (replaced[history[i].key] !== true)
            merged.push(history[i]);
    }

    merged.sort(function (a, b) {
        return (isFinite(b.endedMs) ? b.endedMs : 0) - (isFinite(a.endedMs) ? a.endedMs : 0);
    });
    return merged.slice(0, limit);
}

// ------------------------------------------------------------------ history
//
// A live status file is deleted the moment its action ends, so the directory
// can only ever answer "what is running". How it went is in the event log:
// every wrapper writes one record on every exit path, including the one where
// it was killed. That is where the finished list comes from.
//
// Two shapes, one parser. The state file (~/.local/state/fct.json) holds one
// lowercase JSON record per line; `journalctl -o json` holds the same fields
// as MATRIX_* on a journal entry. Whichever is readable, the rows are the same.
function field(d, name) {
    var lower = d[name];
    if (lower !== undefined && lower !== null)
        return lower;
    var upper = d["MATRIX_" + name.toUpperCase()];
    return upper === undefined || upper === null ? "" : upper;
}

function parseHistory(raw, opts) {
    opts = opts || {};
    var lines = String(raw || "").split("\n");
    var starts = {};
    var rows = [];

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line)
            continue;
        var d;
        try {
            d = JSON.parse(line);
        } catch (e) {
            continue;
        }

        var status = String(field(d, "status")).toLowerCase();
        var command = str(field(d, "command")) || "action";
        var when = timeMs(field(d, "date"));
        if (!isFinite(when))
            when = timeMs(field(d, "epoch"));
        if (!isFinite(when) && d.__REALTIME_TIMESTAMP)
            when = num(d.__REALTIME_TIMESTAMP) / 1000;

        // Not by pid: each record is logged by its own short-lived process, so
        // an action's "started" and "success" never share one. What does
        // identify a run is what it was doing.
        var runKey = identityOf({
            command: command,
            name: str(field(d, "name")),
            source: str(field(d, "source")),
            target: str(field(d, "target"))
        });

        // journalctl prints oldest first, so a "started" is always seen before
        // the record that closes it.
        if (status === "started") {
            starts[runKey] = when;
            continue;
        }
        if (status !== "success" && status !== "fail")
            continue;

        var startedMs = starts[runKey];
        delete starts[runKey];

        // `size` is megabytes by the time it is logged; `total` is a file
        // count, not a byte count.
        var sizeMb = num(field(d, "size"));

        rows.push({
            key: "history/" + runKey + "/" + (isFinite(when) ? when : i),
            file: "",
            id: command + "-" + (isFinite(when) ? when : i),
            pid: num(d._PID),
            command: command,
            status: status,
            phase: status === "fail" ? "failed" : "done",
            paused: false,
            percent: -1,
            bytesDone: NaN,
            bytesTotal: isFinite(sizeMb) ? sizeMb * 1024 * 1024 : NaN,
            files: num(field(d, "total")),
            rate: "",
            eta: "",
            currentFile: "",
            source: str(field(d, "source")),
            target: str(field(d, "target")),
            name: str(field(d, "name")),
            startedMs: isFinite(startedMs) ? startedMs : NaN,
            endedMs: when,
            error: str(field(d, "log")),
            stale: false
        });
    }

    rows.sort(function (a, b) {
        return (isFinite(b.endedMs) ? b.endedMs : 0) - (isFinite(a.endedMs) ? a.endedMs : 0);
    });
    return rows;
}

// What makes two records the same run: the command and what it was pointed at.
function identityOf(a) {
    return [a.command || "", a.source || "", a.target || "", (a.source || a.target) ? "" : (a.name || "")].join("|");
}

// The journal is the truth about how an action ended; a row synthesized from a
// status file that vanished is the stand-in until that record shows up (or
// forever, if the journal cannot be read at all). Same pid, same command: one
// row, the journal's.
function combineHistory(loggedRows, fallbackRows, opts) {
    opts = opts || {};
    var cutoffMs = opts.cutoffMs || 0;
    var limit = opts.historyLimit === undefined ? 20 : opts.historyLimit;
    var known = {};
    var out = [];
    var i;

    for (i = 0; i < loggedRows.length; i++) {
        var j = loggedRows[i];
        var k = identityOf(j);
        // Keep the newest record per identity as the one a stand-in row is
        // measured against, so an earlier copy of the same directory does not
        // swallow the row for the one that just ended.
        if (!isFinite(known[k]) || j.endedMs > known[k])
            known[k] = j.endedMs;
        out.push(j);
    }
    for (i = 0; i < fallbackRows.length; i++) {
        var f = fallbackRows[i];
        var seenAt = known[identityOf(f)];
        // The journal has this run already if it recorded the same action
        // ending after this one started; anything older is a different run.
        if (isFinite(seenAt) && seenAt >= (isFinite(f.startedMs) ? f.startedMs : 0) - 5000)
            continue;
        out.push(f);
    }

    out = out.filter(function (r) {
        return !(isFinite(r.endedMs) && r.endedMs <= cutoffMs);
    });
    out.sort(function (a, b) {
        return (isFinite(b.endedMs) ? b.endedMs : 0) - (isFinite(a.endedMs) ? a.endedMs : 0);
    });
    return out.slice(0, limit);
}
