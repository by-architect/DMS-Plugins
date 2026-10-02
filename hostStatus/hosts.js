.pragma library

// Pure helpers: what scripts/remote.sh printed (plus ssh's exit code and
// stderr) in, one host's state out, and the text a row shows. Side-effect
// free, so it runs outside quickshell -- see tests/tst_hosts.qml.

// Not storage: kernel interfaces, memory-backed and read-only image mounts.
var PSEUDO_FS = ["proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "ramfs", "rootfs", "securityfs", "cgroup", "cgroup2", "pstore", "efivarfs", "bpf", "debugfs", "tracefs", "configfs", "fusectl", "mqueue", "hugetlbfs", "autofs", "binfmt_misc", "rpc_pipefs", "nsfs", "overlay", "squashfs", "erofs", "iso9660", "selinuxfs", "nfsd", "devfs", "fdescfs", "procfs", "linprocfs", "fuse.gvfsd-fuse", "fuse.portal", "fuse.lxcfs", "fuse.snapfuse", "shm", "none", "udev"];

// Somebody else's disk: shown on the machine that owns it, not on every
// machine that mounts it -- and the likeliest thing to make df hang.
var NETWORK_FS = ["nfs", "nfs4", "cifs", "smb3", "smbfs", "9p", "ceph", "glusterfs", "fuse.glusterfs", "fuse.sshfs", "sshfs", "fuse.rclone", "davfs", "fuse.davfs2", "afs"];

function num(v) {
    var n = parseFloat(v);
    return isFinite(n) ? n : NaN;
}

// ------------------------------------------------------------------ parsing

// "cpu  user nice system idle iowait irq softirq steal guest guest_nice".
// guest and guest_nice are already counted inside user and nice.
function parseCpuLine(rest) {
    var f = String(rest).trim().split(/\s+/);
    if (f[0] !== "cpu" || f.length < 5)
        return null;
    var total = 0;
    var v = [];
    for (var i = 1; i < f.length && i <= 8; i++) {
        var n = Number(f[i]);
        if (!isFinite(n))
            return null;
        v.push(n);
        total += n;
    }
    return {
        total: total,
        idle: v[3] + (v.length > 4 ? v[4] : 0)
    };
}

function cpuPercent(a, b) {
    if (!a || !b)
        return -1;
    var dt = b.total - a.total;
    if (!(dt > 0))
        return -1;
    var busy = dt - (b.idle - a.idle);
    return Math.max(0, Math.min(100, 100 * busy / dt));
}

// /proc/mounts writes a space in a mount point as \040, a tab as \011.
function unescapeMount(s) {
    return String(s).replace(/\\([0-7]{3})/g, function (m, o) {
        return String.fromCharCode(parseInt(o, 8));
    });
}

// One `df -P -k` row. The device and the mount point may both hold spaces,
// so the numbers are found from the right: three counts, a capacity, and a
// mount point that starts with "/".
function parseDfLine(rest) {
    var m = /^(.*\S)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+%|-)\s+(\/.*)$/.exec(String(rest));
    if (!m)
        return null;
    return {
        device: m[1],
        totalKb: Number(m[2]),
        usedKb: Number(m[3]),
        availKb: Number(m[4]),
        mount: m[6]
    };
}

function isNetworkDevice(device) {
    // host:/path (nfs, sshfs), remote: (rclone), //server/share (cifs)
    return /^[^/]*:/.test(device) || device.indexOf("//") === 0;
}

function keepFilesystem(d, type) {
    if (!(d.totalKb > 0))
        return false;
    // The root filesystem is always worth a row, whatever it is -- a container
    // or a live image runs on overlay.
    if (d.mount === "/")
        return true;
    if (type)
        return PSEUDO_FS.indexOf(type) < 0 && NETWORK_FS.indexOf(type) < 0;
    // No mount table (not Linux): judge by the device name instead.
    return PSEUDO_FS.indexOf(d.device) < 0 && d.device.indexOf("map ") !== 0 && !isNetworkDevice(d.device);
}

// Real filesystems only, one row per filesystem: a device mounted twice
// (a bind mount, btrfs subvolumes) keeps its shortest mount point. "/" first,
// then by path.
function pickFilesystems(rows, types) {
    var kept = rows.filter(function (d) {
        return keepFilesystem(d, types[d.mount] || "");
    });
    kept.sort(function (a, b) {
        return a.mount.length - b.mount.length;
    });
    var seen = {};
    var out = [];
    for (var i = 0; i < kept.length; i++) {
        var d = kept[i];
        var key = d.device + "|" + d.totalKb;
        if (seen[key])
            continue;
        seen[key] = true;
        var denom = d.usedKb + d.availKb;
        out.push({
            mount: d.mount,
            device: d.device,
            type: types[d.mount] || "",
            total: d.totalKb * 1024,
            used: d.usedKb * 1024,
            avail: d.availKb * 1024,
            // df's own definition of "Capacity": used out of what a user can use.
            percent: denom > 0 ? 100 * d.usedKb / denom : 0
        });
    }
    out.sort(function (a, b) {
        if (a.mount === "/")
            return -1;
        if (b.mount === "/")
            return 1;
        return a.mount < b.mount ? -1 : (a.mount > b.mount ? 1 : 0);
    });
    return out;
}

function parseProbe(text) {
    var out = {
        begun: false,
        complete: false,
        os: "",
        cpuPercent: -1,
        ncpu: 0,
        mem: null,
        swap: null,
        uptimeSec: -1,
        load: null,
        filesystems: []
    };
    var cpus = [];
    var mem = {};
    var types = {};
    var df = [];
    var lines = String(text || "").split("\n");

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/\r$/, "");
        if (line.indexOf("hs:") !== 0)
            continue;
        var sp = line.indexOf(" ");
        var key = sp < 0 ? line.slice(3) : line.slice(3, sp);
        var rest = sp < 0 ? "" : line.slice(sp + 1);

        if (key === "begin") {
            out.begun = true;
        } else if (key === "end") {
            out.complete = true;
        } else if (key === "os") {
            out.os = rest.trim();
        } else if (key === "cpu") {
            var c = parseCpuLine(rest);
            if (c)
                cpus.push(c);
        } else if (key === "ncpu") {
            out.ncpu = parseInt(rest, 10) || 0;
        } else if (key === "mem") {
            var mm = /^(\w+):\s+(\d+)/.exec(rest);
            if (mm)
                mem[mm[1]] = Number(mm[2]) * 1024;
        } else if (key === "uptime") {
            out.uptimeSec = num(rest.trim().split(/\s+/)[0]);
            if (!isFinite(out.uptimeSec))
                out.uptimeSec = -1;
        } else if (key === "load") {
            var l = rest.trim().split(/\s+/).slice(0, 3).map(Number);
            if (l.length === 3 && l.every(isFinite))
                out.load = l;
        } else if (key === "mnt") {
            // A mount point that is mounted over keeps the last (visible) type.
            var f = rest.split(" ");
            if (f.length >= 3)
                types[unescapeMount(f[1])] = f[2];
        } else if (key === "df") {
            var d = parseDfLine(rest);
            if (d)
                df.push(d);
        }
    }

    if (cpus.length >= 2)
        out.cpuPercent = cpuPercent(cpus[0], cpus[cpus.length - 1]);

    if (mem.MemTotal > 0) {
        // MemAvailable is the kernel's own estimate (3.14+); before that, the
        // classic free + buffers + cache.
        var avail = mem.MemAvailable !== undefined ? mem.MemAvailable : (mem.MemFree || 0) + (mem.Buffers || 0) + (mem.Cached || 0);
        out.mem = {
            total: mem.MemTotal,
            used: Math.max(0, mem.MemTotal - avail)
        };
    }
    if (mem.SwapTotal !== undefined) {
        out.swap = {
            total: mem.SwapTotal,
            used: Math.max(0, mem.SwapTotal - (mem.SwapFree || 0))
        };
    }

    out.filesystems = pickFilesystems(df, types);
    return out;
}

// ----------------------------------------------------------- classifying

function _matchLine(text, re) {
    var lines = String(text || "").split(/\r?\n/);
    for (var i = 0; i < lines.length; i++)
        if (re.test(lines[i]))
            return lines[i].replace(/^ssh:\s*/, "").trim().slice(0, 160);
    return "";
}

function _lastLine(text) {
    var lines = String(text || "").split(/\r?\n/).filter(function (l) {
        return l.trim().length > 0;
    });
    return lines.length ? lines[lines.length - 1].replace(/^ssh:\s*/, "").trim().slice(0, 160) : "";
}

// run: { code, stdout, stderr, timedOut, crashed, viaSshpass, timeoutSec }
// Exit codes 90 and 91 come from the local wrapper (no sshpass / no ssh);
// 5-7 are sshpass's own (wrong password, unknown and changed host key).
function classify(run) {
    var stats = parseProbe(run.stdout);
    var err = run.stderr || "";
    var code = run.code;
    var line;

    function verdict(state, detail, s) {
        return {
            state: state,
            detail: detail || "",
            stats: s || null
        };
    }

    if (stats.begun)
        return verdict("online", stats.complete ? "" : "the answer was cut short", stats);
    if (run.timedOut)
        return verdict("unreachable", "no answer within " + (run.timeoutSec || 25) + " s");
    if (code === 91)
        return verdict("error", "ssh is not installed on this machine");
    if (code === 90)
        return verdict("nopass", "needs key auth or sshpass");
    if (run.viaSshpass && code === 5)
        return verdict("auth", "the stored password was rejected");
    if (run.viaSshpass && code === 6)
        return verdict("hostkey", "host key not known yet -- connect once to accept it");
    if (run.viaSshpass && code === 7)
        return verdict("hostkey", "the host key has CHANGED -- check why before trusting it");

    if ((line = _matchLine(err, /REMOTE HOST IDENTIFICATION HAS CHANGED|host key for .* has changed/i)))
        return verdict("hostkey", "the host key has CHANGED -- check why before trusting it");
    if ((line = _matchLine(err, /Host key verification failed|host key is known for/i)))
        return verdict("hostkey", "host key not known yet -- connect once to accept it");
    if ((line = _matchLine(err, /Permission denied|Too many authentication failures|Authentication failed/i)))
        return verdict("auth", line);
    if ((line = _matchLine(err, /Could not resolve hostname|Name or service not known|nodename nor servname|Temporary failure in name resolution/i)))
        return verdict("unreachable", "the name does not resolve");
    if ((line = _matchLine(err, /Connection refused/i)))
        return verdict("unreachable", "connection refused");
    if ((line = _matchLine(err, /No route to host|Network is unreachable|Host is unreachable|Network is down/i)))
        return verdict("unreachable", line);
    if ((line = _matchLine(err, /timed out/i)))
        return verdict("unreachable", "timed out");
    if ((line = _matchLine(err, /Connection closed|Connection reset|kex_exchange_identification|banner exchange/i)))
        return verdict("unreachable", line);
    if (run.crashed)
        return verdict("error", "the check was interrupted");
    if (code === 255)
        return verdict("unreachable", _lastLine(err) || "ssh could not connect");

    // ssh got in and ran something, but not the probe: a forced command, a
    // login shell without sh, a box with no /proc that printed nothing.
    return verdict("online", "connected, but no stats (needs a POSIX sh and /proc)");
}

var STATE_LABELS = {
    online: "online",
    unreachable: "unreachable",
    auth: "auth failed",
    hostkey: "host key not trusted",
    nopass: "not checked",
    error: "error",
    checking: "checking…"
};

function stateLabel(state) {
    return STATE_LABELS[state] || state || "";
}

// A host that refused us is not retried on the timer: a wrong key or password
// every minute is what fail2ban is for. A manual refresh, or a change to the
// host in SSH Hosts, tries again.
function holdsUntilManual(state) {
    return state === "auth" || state === "hostkey";
}

// -------------------------------------------------------------- ssh argv

// Everything that decides how a host is reached -- a change to any of it
// makes the last answer stale.
function sigOf(h) {
    return [h.host, h.port, h.username, h.authMethod, h.identityFile, h.hasPassword ? 1 : 0].join("\u001f");
}

function destText(h) {
    if (!h)
        return "";
    var dest = h.username ? h.username + "@" + h.host : h.host;
    return dest + (h.port && String(h.port) !== "22" ? ":" + h.port : "");
}

// sshManager's buildSshArgs() rules, for when its daemon is not running and
// only its settings can be read.
function fallbackArgv(h, identityPath) {
    if (!h || !h.host)
        return null;
    var argv = ["ssh"];
    if (h.port && String(h.port) !== "22")
        argv.push("-p", String(h.port));
    if (h.authMethod === "key" && identityPath)
        argv.push("-i", identityPath);
    argv.push(h.username ? h.username + "@" + h.host : h.host);
    return argv;
}

function sshOptions(viaSshpass) {
    var opts = ["-T", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
        // Use a ControlMaster the user already has open, but never start a
        // persistent one: it would hold our output pipes open for minutes.
        "-o", "ControlMaster=no", "-o", "LogLevel=ERROR"];
    if (viaSshpass)
        return opts.concat(["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"]);
    return opts.concat(["-o", "BatchMode=yes"]);
}

// ["ssh", "-p", "2222", "user@host"] -> ["ssh", <opts>, "-p", "2222", "--",
// "user@host", remoteCmd]. The destination is always last in sshManager's argv.
function probeArgv(base, opts, remoteCmd) {
    if (!base || base.length < 2)
        return null;
    var dest = base[base.length - 1];
    return [base[0]].concat(opts, base.slice(1, base.length - 1), ["--", dest, remoteCmd]);
}

// ------------------------------------------------------------- formatting

function bytesText(n) {
    if (!isFinite(n) || n < 0)
        return "?";
    var units = ["B", "KB", "MB", "GB", "TB", "PB"];
    var i = 0;
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    return (i === 0 ? n.toFixed(0) : (n < 10 ? n.toFixed(1) : n.toFixed(0))) + " " + units[i];
}

// "5.2 / 16 GB": both numbers in the total's unit.
function pairText(used, total) {
    if (!isFinite(total) || total <= 0)
        return "?";
    var units = ["B", "KB", "MB", "GB", "TB", "PB"];
    var i = 0;
    var div = 1;
    while (total / div >= 1024 && i < units.length - 1) {
        div *= 1024;
        i++;
    }
    function f(v) {
        v = v / div;
        return i === 0 ? v.toFixed(0) : (v < 10 ? v.toFixed(1) : v.toFixed(0));
    }
    return f(used) + " / " + f(total) + " " + units[i];
}

function percentText(p) {
    return isFinite(p) && p >= 0 ? Math.round(p) + "%" : "?";
}

function agoText(ms, nowMs) {
    if (!ms)
        return "never";
    var s = Math.max(0, Math.round((nowMs - ms) / 1000));
    if (s < 5)
        return "just now";
    if (s < 60)
        return s + " s ago";
    if (s < 3600)
        return Math.floor(s / 60) + " min ago";
    if (s < 86400)
        return Math.floor(s / 3600) + " h ago";
    return Math.floor(s / 86400) + " d ago";
}

function uptimeText(sec) {
    if (!isFinite(sec) || sec < 0)
        return "";
    var d = Math.floor(sec / 86400);
    var h = Math.floor(sec % 86400 / 3600);
    var m = Math.floor(sec % 3600 / 60);
    if (d > 0)
        return d + "d " + h + "h";
    if (h > 0)
        return h + "h " + m + "m";
    return m + "m";
}

function loadText(load) {
    return load ? load.map(function (v) {
        return v.toFixed(2);
    }).join(" ") : "";
}
