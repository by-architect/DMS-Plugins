.pragma library

// Everything the widget computes, as pure functions over the text of
// /proc/stat, /proc/meminfo, /proc/loadavg and `ps`, so the arithmetic runs
// and is tested outside quickshell: `node tests/procstat.test.js`.

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

// ------------------------------------------------------------- /proc/stat

// The eight counters that add up to a CPU's whole time, in the kernel's order:
//
//   cpu3  user nice system idle iowait irq softirq steal guest guest_nice
//
// guest and guest_nice are left out on purpose: the kernel already counts them
// inside user and nice, so adding them again would count virtual-machine time
// twice. Of the eight, idle and iowait are the time the CPU had nothing to
// run -- waiting on a disk is not work.
var FIELDS = 8;

// One "cpu" line -> { id, f: [8 counters] }; id is -1 for the aggregate line.
function parseCpuLine(line) {
    var m = /^cpu(\d*)\s+(.*)$/.exec(line);
    if (!m)
        return null;
    var parts = m[2].trim().split(/\s+/);
    if (parts.length < 4)
        return null;
    var f = [];
    for (var i = 0; i < FIELDS; i++) {
        var n = i < parts.length ? Number(parts[i]) : 0;
        if (!isFinite(n))
            return null;
        f.push(n);
    }
    return {
        id: m[1] === "" ? -1 : parseInt(m[1], 10),
        f: f
    };
}

// The whole file -> { all, cores }: the aggregate line and one entry per core,
// by core number. Numbers can have gaps (an offline CPU has no line at all),
// so a core is always named by its own number, never by its position.
function parseStat(text) {
    var out = {
        all: null,
        cores: []
    };
    var lines = (text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.lastIndexOf("cpu", 0) !== 0) {
            // The cpu block comes first and is contiguous; nothing after it
            // (intr alone is thousands of numbers) is worth a regex.
            if (out.all || out.cores.length > 0)
                break;
            continue;
        }
        var c = parseCpuLine(line);
        if (!c)
            continue;
        if (c.id < 0)
            out.all = c;
        else
            out.cores.push(c);
    }
    out.cores.sort(function (a, b) {
        return a.id - b.id;
    });
    return out;
}

// How busy one CPU (or the aggregate) was between two readings, 0..100, or -1
// when the pair describes no usable interval.
//
// Each counter's delta is floored at zero before anything is added up, the way
// psutil does it: iowait is documented to go backwards now and then, and a CPU
// taken offline and back restarts its counters from zero. Without the floor the
// first gives a reading above 100% and the second a negative one; with it,
// the second simply has no elapsed time and says so.
function busyPercent(prev, cur) {
    if (!prev || !cur)
        return -1;
    var total = 0;
    var idle = 0;
    for (var i = 0; i < FIELDS; i++) {
        var d = Math.max(0, cur.f[i] - prev.f[i]);
        total += d;
        if (i === 3 || i === 4)
            idle += d;
    }
    if (total <= 0)
        return -1;
    return clamp((total - idle) / total * 100, 0, 100);
}

// Two parseStat() results -> { total, cores: [{ id, usage }] }. A core with no
// earlier reading (the first sample, or one just brought online) gets -1.
function measure(prev, cur) {
    var byId = {};
    if (prev) {
        for (var i = 0; i < prev.cores.length; i++)
            byId[prev.cores[i].id] = prev.cores[i];
    }
    var cores = [];
    for (var j = 0; j < cur.cores.length; j++) {
        var c = cur.cores[j];
        cores.push({
            id: c.id,
            usage: busyPercent(byId[c.id], c)
        });
    }
    return {
        total: prev ? busyPercent(prev.all, cur.all) : -1,
        cores: cores
    };
}

function busiest(cores) {
    var best = null;
    for (var i = 0; i < (cores || []).length; i++) {
        var c = cores[i];
        if (c.usage >= 0 && (!best || c.usage > best.usage))
            best = c;
    }
    return best;
}

// 0 normal, 1 warning, 2 critical. A critical threshold set below the warning
// one is read as equal to it, so a slider pushed past the other never makes a
// level unreachable.
function levelFor(value, warn, crit) {
    if (!(value >= 0))
        return 0;
    var w = Math.max(0, warn);
    var c = Math.max(w, crit);
    if (value >= c)
        return 2;
    if (value >= w)
        return 1;
    return 0;
}

function percentText(value) {
    return value >= 0 ? Math.round(value) + "%" : "--%";
}

// --------------------------------------------------- meminfo and loadavg

// "In use" is MemTotal - MemAvailable, the same figure `free` reports as used:
// MemFree alone would count the page cache, which the kernel hands back the
// moment anything asks, as memory in use.
function parseMeminfo(text) {
    var kb = {};
    var lines = (text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var m = /^([A-Za-z0-9_()]+):\s+(\d+)/.exec(lines[i]);
        if (m)
            kb[m[1]] = Number(m[2]);
    }
    if (!(kb.MemTotal > 0))
        return null;
    // MemAvailable exists since Linux 3.14; before it, free + buffers + cache
    // was the usual estimate.
    var available = kb.MemAvailable !== undefined ? kb.MemAvailable : (kb.MemFree || 0) + (kb.Buffers || 0) + (kb.Cached || 0);
    var swapTotal = kb.SwapTotal || 0;
    var swapFree = kb.SwapFree !== undefined ? kb.SwapFree : swapTotal;
    return {
        totalKb: kb.MemTotal,
        usedKb: Math.max(0, kb.MemTotal - available),
        availableKb: available,
        swapTotalKb: swapTotal,
        swapUsedKb: Math.max(0, swapTotal - swapFree)
    };
}

// "18.15 18.98 18.32 4/1919 2201" -> the three averages, plus how many tasks
// are runnable right now out of how many exist.
function parseLoadavg(text) {
    var f = (text || "").trim().split(/\s+/);
    if (f.length < 3)
        return null;
    var one = Number(f[0]);
    var five = Number(f[1]);
    var fifteen = Number(f[2]);
    if (!isFinite(one) || !isFinite(five) || !isFinite(fifteen))
        return null;
    var rt = /^(\d+)\/(\d+)$/.exec(f[3] || "");
    return {
        one: one,
        five: five,
        fifteen: fifteen,
        running: rt ? Number(rt[1]) : 0,
        tasks: rt ? Number(rt[2]) : 0
    };
}

function formatKb(kb) {
    if (!(kb >= 0))
        return "?";
    var gib = kb / 1048576;
    if (gib >= 100)
        return gib.toFixed(0) + " GiB";
    if (gib >= 1)
        return gib.toFixed(1) + " GiB";
    return (kb / 1024).toFixed(0) + " MiB";
}

function loadText(load) {
    if (!load)
        return "";
    return load.one.toFixed(2) + " · " + load.five.toFixed(2) + " · " + load.fifteen.toFixed(2);
}

// --------------------------------------------------------------------- ps

// `ps -eo pid=,user=,pcpu=,pmem=,args= --sort=-pcpu ww`, one process a line.
// pid, user, %cpu and %mem are always single tokens; args is whatever is left,
// taken whole rather than split, since a command line is free to contain any
// amount of whitespace.
var PS_LINE = /^(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+([\s\S]*)$/;

function basename(p) {
    var slash = p.lastIndexOf("/");
    return slash >= 0 ? p.substring(slash + 1) : p;
}

// What a row is called: the program, not its path. Kernel threads come from
// ps already bracketed ("[kswapd0]") and stay as they are. NixOS runs most
// programs through a wrapper whose real binary is `.name-wrapped` -- sometimes
// wrapped twice, `..name-wrapped-wrapped` -- so that is unwrapped, and the
// colon of a retitled process ("sshd: neo@pts/0") is dropped.
function displayName(args) {
    if (!args)
        return "(unknown)";
    if (args.charAt(0) === "[")
        return args;
    var name = basename(args.split(/\s+/)[0] || "");
    var wrapped = /^\.+(.+?)(?:-wrapped)+$/.exec(name);
    if (wrapped)
        name = wrapped[1];
    name = name.replace(/:$/, "");
    return name || "(unknown)";
}

// ps prints its numbers with a dot whatever LC_NUMERIC says (checked with
// tr_TR, which uses a comma) -- the comma is accepted anyway, in case some ps
// ever does follow the locale.
function parseNumber(s) {
    var n = parseFloat(String(s).replace(",", "."));
    return isFinite(n) ? n : 0;
}

// -> [{ pid, user, pcpu, pmem, args, display }], already in ps's order
// (heaviest first), at most opts.limit long. The ps doing the listing always
// measures its own short burst and would sit near the top of every refresh,
// so anything named opts.skipName is left out.
function parseProcesses(text, opts) {
    var limit = opts && opts.limit > 0 ? opts.limit : Infinity;
    var skip = opts && opts.skipName ? opts.skipName : "";
    var out = [];
    var lines = (text || "").split("\n");
    for (var i = 0; i < lines.length && out.length < limit; i++) {
        var m = PS_LINE.exec(lines[i].trim());
        if (!m)
            continue;
        var args = m[5];
        var display = displayName(args);
        if (skip && display === skip)
            continue;
        out.push({
            pid: m[1],
            user: m[2],
            pcpu: parseNumber(m[3]),
            pmem: parseNumber(m[4]),
            args: args,
            display: display
        });
    }
    return out;
}

function shorten(text, max) {
    var s = String(text || "");
    return s.length > max ? s.substring(0, max - 1) + "…" : s;
}

function firstLine(text) {
    var lines = (text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var t = lines[i].trim();
        if (t.length > 0)
            return t.length > 300 ? t.substring(0, 300) + "…" : t;
    }
    return "";
}

// ------------------------------------------------------------------- kill

function looksLikeQuickshell(args) {
    return String(args || "").toLowerCase().indexOf("quickshell") >= 0;
}

// The shell running this bar: its own PID, or "quickshell" anywhere in the
// command line (which also covers `dms run`, whose command line names the
// quickshell config it starts).
function isShell(entry, shellPid) {
    return !!entry && (Number(entry.pid) === shellPid || looksLikeQuickshell(entry.args));
}

// Whether a PID may be signalled at all. Digits only and above 1: `kill 0`
// signals the caller's whole process group and `kill -1` every process the
// user owns, so neither may ever be reachable from a row.
function validPid(pid) {
    return /^[0-9]+$/.test(String(pid)) && Number(pid) > 1;
}

// The verdict on a kill, from a fresh `ps -p PID -o args= ww` taken right
// before the signal would be sent. Only "ok" leads to a kill.
//
//   invalid    not a PID that may be signalled (see validPid)
//   shell      quickshell itself -- by PID, or by either command line
//   unchecked  ps did not answer (-1 is the worker's timeout), so nothing is known
//   gone       no process has that PID any more
//   reused     the PID now belongs to a different command line: the process the
//              list showed has exited and its number was handed on
function killVerdict(entry, currentOut, exitCode, shellPid) {
    if (!entry || !validPid(entry.pid))
        return "invalid";
    if (isShell(entry, shellPid))
        return "shell";
    if (exitCode === -1)
        return "unchecked";
    var current = (currentOut || "").trim();
    if (exitCode !== 0 || current.length === 0)
        return "gone";
    if (looksLikeQuickshell(current))
        return "shell";
    if (current !== entry.args)
        return "reused";
    return "ok";
}
