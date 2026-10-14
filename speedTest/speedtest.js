.pragma library

// Everything the widget works out, as pure functions: what a speed test
// program printed in, one result out; when the next test is due; and the
// text the pill and the popout show. Tested outside quickshell:
// `node tests/speedtest.test.js`.

function num(v) {
    var n = Number(v);
    return isFinite(n) ? n : -1;
}

function jsonValues(text) {
    var out = [];
    var s = String(text || "").trim();
    if (!s)
        return out;
    // One document (speedtest-cli, librespeed-cli), or one per line (Ookla
    // can put log records before its result).
    try {
        out.push(JSON.parse(s));
        return out;
    } catch (e) {}
    var lines = s.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line.charAt(0) !== "{" && line.charAt(0) !== "[")
            continue;
        try {
            out.push(JSON.parse(line));
        } catch (e2) {}
    }
    return out;
}

// What any of the three programs printed -> one result, speeds in Mbit/s:
//
//   { down, up, ping, jitter, loss, server, location, isp, ip, url, tool }
//
// or null when nothing in the text is a result. -1 for anything a program
// did not report.
//
//   Ookla        {"type":"result","download":{"bandwidth":<bytes/s>},…}
//   speedtest-cli {"download":<bit/s>,"upload":<bit/s>,"ping":<ms>,…}
//   librespeed   [{"download":<Mbit/s>,"upload":<Mbit/s>,"ping":<ms>,…}]
function parseResult(text) {
    var docs = jsonValues(text);
    for (var i = docs.length - 1; i >= 0; i--) {
        var d = docs[i];
        if (Array.isArray(d))
            d = d.length > 0 ? d[0] : null;
        if (!d || typeof d !== "object")
            continue;

        if (d.download && typeof d.download === "object" && d.download.bandwidth !== undefined) {
            var srv = d.server || {};
            return {
                down: num(d.download.bandwidth) * 8 / 1e6,
                up: d.upload ? num(d.upload.bandwidth) * 8 / 1e6 : -1,
                ping: d.ping ? num(d.ping.latency) : -1,
                jitter: d.ping ? num(d.ping.jitter) : -1,
                loss: d.packetLoss !== undefined ? num(d.packetLoss) : -1,
                server: srv.name || "",
                location: [srv.location, srv.country].filter(Boolean).join(", "),
                isp: d.isp || "",
                ip: d["interface"] ? d["interface"].externalIp || "" : "",
                url: d.result ? d.result.url || "" : "",
                tool: "Ookla speedtest"
            };
        }

        // speedtest-cli's server has a sponsor and its client an ISP;
        // librespeed's has neither.
        if (typeof d.download === "number" && ((d.server && d.server.sponsor !== undefined) || (d.client && d.client.isp !== undefined))) {
            var s = d.server || {};
            var c = d.client || {};
            var km = num(s.d);
            return {
                down: d.download / 1e6,
                up: typeof d.upload === "number" ? d.upload / 1e6 : -1,
                ping: num(d.ping),
                jitter: -1,
                loss: -1,
                server: s.sponsor || "",
                location: [s.name, s.country].filter(Boolean).join(", ") + (km >= 0 ? " (" + Math.round(km) + " km)" : ""),
                isp: c.isp || "",
                ip: c.ip || "",
                url: d.share || "",
                // scripts/nearest.py: the same engine, on the servers
                // speedtest.net lists as nearest.
                tool: d.picked === "nearest" ? "speedtest-cli, nearest server" : "speedtest-cli"
            };
        }

        if (typeof d.download === "number") {
            var ls = d.server || {};
            return {
                down: d.download,
                up: typeof d.upload === "number" ? d.upload : -1,
                ping: num(d.ping),
                jitter: num(d.jitter),
                loss: -1,
                server: ls.name || "",
                location: "",
                isp: d.client && d.client.org ? d.client.org : "",
                ip: d.client && d.client.ip ? d.client.ip : "",
                url: d.share || "",
                tool: "librespeed-cli"
            };
        }
    }
    return null;
}

// Why a run failed, in one line: the program's own "ERROR: …" when it gave
// one, else its last word on stderr.
function errorLine(stderr, code) {
    var lines = String(stderr || "").split("\n").map(function (l) {
        return l.trim();
    }).filter(function (l) {
        return l.length > 0;
    });
    for (var i = lines.length - 1; i >= 0; i--) {
        var m = /^(?:ERROR|\[error\]|error)[:\s]+(.*)$/i.exec(lines[i]);
        if (m)
            return m[1].trim().slice(0, 240);
    }
    if (lines.length > 0)
        return lines[lines.length - 1].slice(0, 240);
    if (code === -1)
        return "the test did not finish in time";
    return code ? "the speed test exited with code " + code : "the speed test printed no result";
}

// ------------------------------------------------------------- schedule

// When the next automatic test is due, in ms, or 0 for never.
//
//   intervalMin   minutes between tests; 0 means only when asked
//   lastMs        when the last test started, 0 for never
//   failed        whether that test failed: then it is tried again after
//                 retryMin, or the interval if that is shorter
//   readyMs       not before this: the shell's start plus a grace period,
//                 so a test does not race the network coming up at login
function nextDue(intervalMin, lastMs, failed, retryMin, readyMs) {
    if (!(intervalMin > 0))
        return 0;
    var wait = (failed ? Math.min(retryMin, intervalMin) : intervalMin) * 60000;
    var due = lastMs > 0 ? lastMs + wait : 0;
    return Math.max(due, readyMs || 0);
}

// ----------------------------------------------------------------- text

// "940", "94", "9.4", "1.2G" -- the pill's short form, Mbit/s implied.
function shortMbps(v) {
    if (!(v >= 0))
        return "--";
    if (v >= 1000)
        return (v / 1000).toFixed(v >= 10000 ? 0 : 1) + "G";
    if (v >= 10)
        return Math.round(v) + "";
    return v.toFixed(1);
}

function mbpsText(v) {
    if (!(v >= 0))
        return "--";
    if (v >= 1000)
        return (v / 1000).toFixed(v >= 10000 ? 0 : 2) + " Gbit/s";
    return (v >= 100 ? Math.round(v) : v.toFixed(1)) + " Mbit/s";
}

function msText(v) {
    if (!(v >= 0))
        return "--";
    return (v >= 100 ? Math.round(v) : v.toFixed(1)) + " ms";
}

// What the pill says: "↓94 ↑12", "↓94", or with the ping, "↓94 ↑12 18ms".
function pillText(result, shows) {
    if (!result)
        return "--";
    var down = "↓" + shortMbps(result.down);
    if (shows === "down")
        return down;
    var both = down + " ↑" + shortMbps(result.up);
    if (shows === "all")
        return both + " " + (result.ping >= 0 ? Math.round(result.ping) + "ms" : "--");
    return both;
}

function agoText(ms, nowMs) {
    if (!ms)
        return "never";
    var s = Math.max(0, Math.round((nowMs - ms) / 1000));
    if (s < 60)
        return "just now";
    if (s < 3600)
        return Math.floor(s / 60) + " min ago";
    if (s < 86400)
        return Math.floor(s / 3600) + " h " + (Math.floor(s / 60) % 60) + " min ago";
    return Math.floor(s / 86400) + " d ago";
}

function inText(ms, nowMs) {
    var s = Math.max(0, Math.round((ms - nowMs) / 1000));
    if (s < 60)
        return "in under a minute";
    if (s < 3600)
        return "in " + Math.ceil(s / 60) + " min";
    var h = Math.floor(s / 3600);
    var m = Math.round((s % 3600) / 60);
    return "in " + h + " h" + (m > 0 ? " " + m + " min" : "");
}

function clockText(ms) {
    var d = new Date(ms);
    function p(n) {
        return n < 10 ? "0" + n : "" + n;
    }
    var today = new Date();
    var sameDay = d.getFullYear() === today.getFullYear() && d.getMonth() === today.getMonth() && d.getDate() === today.getDate();
    return (sameDay ? "" : p(d.getDate()) + "." + p(d.getMonth() + 1) + " ") + p(d.getHours()) + ":" + p(d.getMinutes());
}
