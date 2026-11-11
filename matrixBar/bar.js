.pragma library

// Pure helpers: what scripts/probe.sh prints in, one machine's numbers out.
// Side-effect free, so it runs outside quickshell -- see tests/tst_bar.qml.
//
// A machine streams snapshots (mx:begin ... mx:end) for as long as its
// connection lasts. parseSnapshot() reads one; advance() folds it into what
// the machine looked like before, because CPU and GPU use are rates -- two
// readings apart -- and the slow parts (storage, Syncthing, a phone's data
// counter) arrive only every few snapshots and are kept in between.

// ------------------------------------------------------------------ storage
// The same rules as hostStatus: what counts as a disk, and what does not.

// Not storage: kernel interfaces, memory-backed and read-only image mounts.
var PSEUDO_FS = ["proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "ramfs", "rootfs", "securityfs", "cgroup", "cgroup2", "pstore", "efivarfs", "bpf", "debugfs", "tracefs", "configfs", "fusectl", "mqueue", "hugetlbfs", "autofs", "binfmt_misc", "rpc_pipefs", "nsfs", "overlay", "squashfs", "erofs", "iso9660", "selinuxfs", "nfsd", "devfs", "fdescfs", "procfs", "linprocfs", "fuse.gvfsd-fuse", "fuse.portal", "fuse.lxcfs", "fuse.snapfuse", "shm", "none", "udev"];

// Somebody else's disk: shown on the machine that owns it, not on every
// machine that mounts it.
var NETWORK_FS = ["nfs", "nfs4", "cifs", "smb3", "smbfs", "9p", "ceph", "glusterfs", "fuse.glusterfs", "fuse.sshfs", "sshfs", "fuse.rclone", "davfs", "fuse.davfs2", "afs"];

// The boot partition is written by rebuilds, never filled by hand: hidden
// unless it is nearly full, the one time it matters.
var BOOT_MOUNTS = ["/boot", "/boot/efi", "/boot/firmware", "/efi"];
var BOOT_SHOW_PERCENT = 90;

var UNSET = 2147483647; // what Android prints for "no value"

function num(v) {
    var n = Number(v);
    return isFinite(n) ? n : NaN;
}

function clampPct(v) {
    return isFinite(v) ? Math.max(0, Math.min(100, v)) : -1;
}

function pctOf(used, total) {
    return total > 0 ? clampPct(100 * used / total) : -1;
}

// ------------------------------------------------------------------ reading

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
    return clampPct(100 * (dt - (b.idle - a.idle)) / dt);
}

// Intel: busy is the share of the time between two readings the GPU did
// not spend asleep in RC6. ms is the counter, up the uptime it was read at.
function gpuIdlePercent(a, b) {
    if (!a || !b)
        return -1;
    var wall = (b.up - a.up) * 1000;
    if (!(wall > 0))
        return -1;
    return clampPct(100 * (1 - (b.ms - a.ms) / wall));
}

// Intel's i915, from the programs using it: how long each kept each engine
// (render, copy, video, video-enhance, compute) busy between two readings,
// summed over the programs seen both times. The busiest engine is the GPU's
// load, as intel_gpu_top shows it.
function drmPercent(a, b) {
    if (!a || !b)
        return -1;
    var wall = (b.up - a.up) * 1e9;
    if (!(wall > 0))
        return -1;
    var sums = [0, 0, 0, 0, 0];
    for (var id in b.clients) {
        var x = a.clients[id];
        if (!x)
            continue;
        var y = b.clients[id];
        for (var e = 0; e < 5; e++)
            sums[e] += Math.max(0, (y[e] || 0) - (x[e] || 0));
    }
    return clampPct(100 * Math.max.apply(null, sums) / wall);
}

// /proc/mounts writes a space in a mount point as \040, a tab as \011.
function unescapeMount(s) {
    return String(s).replace(/\\([0-7]{3})/g, function (m, o) {
        return String.fromCharCode(parseInt(o, 8));
    });
}

// One `df -P -k` row. The device and the mount point may both hold spaces,
// so the numbers are found from the right.
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

function emptySnapshot() {
    return {
        begun: false,
        complete: false,
        seq: -1,
        full: false,
        up: NaN,
        host: "",
        android: null,
        root: null,
        ncpu: 0,
        cpu: [],
        gpuBusy: {},
        gpuIdle: {},
        drm: [],
        mem: null,
        batteries: [],
        ssh: null,
        sshPeers: null,
        storage: null,
        sync: null,
        jobs: null,
        props: {},
        settings: {},
        tel: [],
        wifi: [],
        uplink: null,
        tether: null,
        missed: null,
        policy: null,
        dataRows: null
    };
}

// One snapshot's lines (mx:begin through mx:end) -> what they say.
function parseSnapshot(text) {
    var s = emptySnapshot();
    var types = {};
    var devices = {};
    var df = [];
    var blk = {};
    var st = null; // Syncthing's raw answers, until the end
    var sawStorage = false;
    var lines = Array.isArray(text) ? text : String(text || "").split("\n");

    for (var i = 0; i < lines.length; i++) {
        var line = String(lines[i]).replace(/\r$/, "");
        if (line.indexOf("mx:") !== 0)
            continue;
        var body = line.slice(3);
        var sp = body.indexOf(" ");
        var tag = sp < 0 ? body : body.slice(0, sp);
        var rest = sp < 0 ? "" : body.slice(sp + 1);
        var f;

        switch (tag) {
        case "begin":
            f = rest.trim().split(/\s+/);
            s.begun = true;
            s.seq = parseInt(f[0], 10);
            s.full = f[1] === "1";
            break;
        case "end":
            s.complete = true;
            break;
        case "t":
            s.up = num(rest.trim());
            break;
        case "host":
            s.host = rest.trim();
            break;
        case "android":
            f = rest.trim().split(/\s+/);
            s.android = f[0] === "1";
            s.root = f[1] === "1";
            break;
        case "ncpu":
            s.ncpu = parseInt(rest, 10) || 0;
            break;
        case "cpu":
            var c = parseCpuLine(rest);
            if (c)
                s.cpu.push(c);
            break;
        case "gpu":
            f = rest.trim().split(/\s+/);
            if (f[0] === "busy" && f.length >= 3 && isFinite(num(f[2]))) {
                s.gpuBusy[f[1]] = num(f[2]);
            } else if (f[0] === "idle" && f.length >= 4 && isFinite(num(f[2])) && isFinite(num(f[3]))) {
                (s.gpuIdle[f[1]] = s.gpuIdle[f[1]] || []).push({
                    ms: num(f[2]),
                    up: num(f[3])
                });
            }
            break;
        case "drm":
            // "<uptime> <client> <render> <copy> <video> <video-enhance> <compute>"
            f = rest.trim().split(/\s+/);
            if (f.length >= 7 && isFinite(num(f[0]))) {
                var up = num(f[0]);
                var last = s.drm.length ? s.drm[s.drm.length - 1] : null;
                if (!last || last.up !== up) {
                    last = {
                        up: up,
                        clients: {}
                    };
                    s.drm.push(last);
                }
                last.clients[f[1]] = f.slice(2, 7).map(num);
            }
            break;
        case "mem":
            f = rest.trim().split(/\s+/).map(num);
            if (f.length >= 4 && f[0] > 0)
                s.mem = {
                    totalKb: f[0],
                    availKb: f[1],
                    swapTotalKb: f[2] || 0,
                    swapFreeKb: f[3] || 0
                };
            break;
        case "bat":
            f = rest.trim().split(/\s+/);
            if (f.length >= 2 && isFinite(num(f[1])))
                s.batteries.push({
                    name: f[0],
                    level: num(f[1]),
                    status: (f[2] || "").replace(/_/g, " ")
                });
            break;
        case "ssh":
            f = rest.trim().split(/\s+/).map(num);
            s.ssh = {
                tty: f[0] || 0,
                notty: f[1] || 0,
                self: f[2] || 0
            };
            break;
        case "mnt":
            sawStorage = true;
            f = rest.split(" ");
            if (f.length >= 3) {
                var at = unescapeMount(f[1]);
                // A mount point that is mounted over keeps the last type.
                types[at] = f[2];
                devices[at] = f[0];
            }
            break;
        case "df":
            sawStorage = true;
            var d = parseDfLine(rest);
            if (d)
                df.push(d);
            break;
        case "blk":
            f = rest.trim().split(/\s+/);
            if (f.length >= 4)
                blk[f[0]] = {
                    disk: f[1],
                    removable: f[2] === "1",
                    bus: f[3]
                };
            break;
        case "sshpeer":
            s.sshPeers = s.sshPeers || [];
            s.sshPeers.push(peerHost(rest.trim()));
            break;
        case "stpause":
            st = st || emptySyncRaw();
            st.pauseFile = true;
            break;
        case "stoff":
            st = st || emptySyncRaw();
            st.running = false;
            break;
        case "sterr":
            st = st || emptySyncRaw();
            st.error = rest.trim();
            break;
        case "stfolders":
            st = st || emptySyncRaw();
            st.folders = [];
            break;
        case "stfolder":
            // "<id> <paused 0|1> <label>"
            st = st || emptySyncRaw();
            f = /^(\S+)\s+(\d)\s?(.*)$/.exec(rest);
            if (f) {
                st.folders = st.folders || [];
                st.folders.push({
                    id: f[1],
                    paused: f[2] === "1",
                    label: f[3] || f[1]
                });
            }
            break;
        case "stdevs":
            st = st || emptySyncRaw();
            st.connections = {};
            break;
        case "stdev":
            // "<connected 0|1> <paused 0|1>", one per other device
            st = st || emptySyncRaw();
            f = rest.trim().split(/\s+/);
            st.connections = st.connections || {};
            st.connections["d" + Object.keys(st.connections).length] = {
                connected: f[0] === "1",
                paused: f[1] === "1"
            };
            break;
        case "ststatus":
            // "<folder> <state> <files to fetch> <bytes to fetch> <failed>"
            st = st || emptySyncRaw();
            f = rest.trim().split(/\s+/);
            if (f.length >= 2)
                st.status[f[0]] = {
                    state: f[1],
                    needFiles: num(f[2]) || 0,
                    needBytes: num(f[3]) || 0,
                    pullErrors: num(f[4]) || 0
                };
            break;
        case "jobs":
            s.jobs = s.jobs || {
                units: [],
                running: []
            };
            break;
        case "units":
            // The unit lines follow; "same": as the snapshot before.
            s.jobs = s.jobs || {
                units: [],
                running: []
            };
            s.jobs.unitsSame = rest.trim() === "same";
            break;
        case "unit":
            f = rest.trim().split(/\s+/);
            s.jobs = s.jobs || {
                units: [],
                running: []
            };
            if (f.length >= 3)
                s.jobs.units.push({
                    unit: f[0],
                    active: f[1],
                    sub: f[2]
                });
            break;
        case "job":
            s.jobs = s.jobs || {
                units: [],
                running: []
            };
            var job = parseJobLine(rest);
            if (job)
                s.jobs.running.push(job);
            break;
        case "uplink":
            s.uplink = rest.trim();
            break;
        case "tether":
            s.tether = rest.trim() === "" ? [] : rest.trim().split(/\s+/);
            break;
        case "prop":
            var ps = rest.indexOf(" ");
            if (ps < 0)
                s.props[rest] = "";
            else
                s.props[rest.slice(0, ps)] = rest.slice(ps + 1).trim();
            break;
        case "setting":
            f = rest.split(" ");
            s.settings[f[0]] = (f[1] || "").trim();
            break;
        case "tel":
            s.tel.push(rest);
            break;
        case "wifi":
            s.wifi.push(rest);
            break;
        case "missed":
            s.missed = parseInt(rest, 10) || 0;
            break;
        case "policy":
            s.policy = rest;
            s.dataRows = s.dataRows || [];
            break;
        case "data":
            f = rest.split(" ");
            s.dataRows = s.dataRows || [];
            s.dataRows.push({
                st: num(f[0]),
                rx: num(f[1]) || 0,
                tx: num(f[2]) || 0
            });
            break;
        }
    }

    if (sawStorage)
        s.storage = s.android ? androidStorage(df, types, devices) : linuxStorage(df, types, devices, blk);
    if (st)
        s.sync = syncState(st);
    return s;
}

// "100.70.50.2:47048" -> "100.70.50.2"; "[fd7a::1]:22" -> "fd7a::1".
function peerHost(peer) {
    var m = /^\[(.*)\]:\d+$/.exec(peer) || /^(.*):\d+$/.exec(peer);
    return m ? m[1] : peer;
}

// ------------------------------------------------------------ storage

function isNetworkDevice(device) {
    // host:/path (nfs, sshfs), remote: (rclone), //server/share (cifs)
    return /^[^/]*:/.test(device) || device.indexOf("//") === 0;
}

function keepFilesystem(d, type) {
    if (!(d.totalKb > 0))
        return false;
    // The root filesystem is always worth a bar, whatever it is.
    if (d.mount === "/")
        return true;
    if (type)
        return PSEUDO_FS.indexOf(type) < 0 && NETWORK_FS.indexOf(type) < 0;
    return PSEUDO_FS.indexOf(d.device) < 0 && !isNetworkDevice(d.device);
}

function fsEntry(d, types, label) {
    var denom = d.usedKb + d.availKb;
    return {
        mount: d.mount,
        label: label || "",
        device: d.device,
        type: types[d.mount] || "",
        total: d.totalKb * 1024,
        used: d.usedKb * 1024,
        avail: d.availKb * 1024,
        // df's own "Capacity": used out of what a user can use.
        percent: denom > 0 ? 100 * d.usedKb / denom : 0
    };
}

function isBootMount(mount) {
    return BOOT_MOUNTS.indexOf(mount) >= 0;
}

// A short name for a removable volume: the last part of where it is
// mounted (/run/media/neo/STICK -> STICK).
function volumeName(mount) {
    var i = mount.lastIndexOf("/");
    return i >= 0 && i < mount.length - 1 ? mount.slice(i + 1) : mount;
}

// Every real filesystem, one per device (a bind mount or a btrfs subvolume
// is the same space again), split into the machine's own disks and what can
// be pulled out of it. A disk counts as removable when the kernel says so,
// or it hangs off USB or an SD card slot -- unless "/" is on it, which makes
// it this machine's disk whatever bus it is on. Disks: "/" first, then the
// biggest; removable ones by mount point.
//
// df and the mount table do not always name a device alike (df says
// /dev/dm-1 where /proc/mounts says /dev/mapper/luks-…), so a row's disk is
// looked up through its mount point: devices maps that to the mount table's
// name, which is what blk is keyed by.
function linuxStorage(rows, types, devices, blk) {
    function blkOf(d) {
        return blk[devices[d.mount]] || blk[d.device] || null;
    }
    var kept = rows.filter(function (d) {
        return keepFilesystem(d, types[d.mount] || "");
    });
    kept.sort(function (a, b) {
        return a.mount.length - b.mount.length;
    });
    var rootDisk = "";
    for (var r = 0; r < kept.length; r++) {
        if (kept[r].mount === "/" && blkOf(kept[r]))
            rootDisk = blkOf(kept[r]).disk;
    }
    var seen = {};
    var disks = [];
    var removable = [];
    for (var i = 0; i < kept.length; i++) {
        var d = kept[i];
        var key = d.device + "|" + d.totalKb;
        if (seen[key])
            continue;
        seen[key] = true;
        var e = fsEntry(d, types, "");
        var b = blkOf(d);
        var pullable = !!b && b.disk !== rootDisk && (b.removable || b.bus === "usb" || b.bus === "mmc");
        if (pullable) {
            e.label = volumeName(e.mount);
            e.bus = b.bus;
            removable.push(e);
            continue;
        }
        if (isBootMount(e.mount) && e.percent < BOOT_SHOW_PERCENT)
            continue;
        disks.push(e);
    }
    disks.sort(function (a, b) {
        if (a.mount === "/")
            return -1;
        if (b.mount === "/")
            return 1;
        return b.total - a.total;
    });
    removable.sort(function (a, b) {
        return a.mount < b.mount ? -1 : (a.mount > b.mount ? 1 : 0);
    });
    return {
        disks: disks,
        removable: removable
    };
}

// What kind of removable volume /storage/<ID> is, from the block device
// behind its other mount, /mnt/media_rw/<ID>: vold names it
// "/dev/block/vold/public:<major>,<minor>", and major 8 is a USB disk.
// Anything else counts as an SD card -- the common case on a phone.
function androidVolumeKind(mount, devices) {
    var id = mount.substring(mount.lastIndexOf("/") + 1);
    var dev = devices["/mnt/media_rw/" + id] || "";
    var m = /public:(\d+),/.exec(dev);
    return m && m[1] === "8" ? "usb" : "sd";
}

// A phone mounts dozens of filesystems nobody fills. What is the user's:
// internal storage (/storage/emulated, the /data partition as apps see it;
// /data itself when that is all there is), and each removable volume,
// /storage/<ID> -- an SD card or a USB drive.
function androidStorage(rows, types, devices) {
    var internal = null;
    var data = null;
    var removable = [];
    for (var i = 0; i < rows.length; i++) {
        var d = rows[i];
        if (!(d.totalKb > 0))
            continue;
        if (d.mount === "/storage/emulated" || d.mount === "/storage/emulated/0") {
            if (!internal)
                internal = d;
        } else if (d.mount === "/data") {
            data = d;
        } else if (/^\/storage\/[^/]+$/.test(d.mount) && d.mount !== "/storage/self") {
            removable.push(d);
        }
    }
    internal = internal || data;
    removable.sort(function (a, b) {
        return a.mount < b.mount ? -1 : (a.mount > b.mount ? 1 : 0);
    });
    return {
        disks: internal ? [fsEntry(internal, types, "Internal")] : [],
        removable: removable.map(function (d) {
            var kind = androidVolumeKind(d.mount, devices);
            var e = fsEntry(d, types, kind === "usb" ? "USB drive" : "SD card");
            e.bus = kind === "usb" ? "usb" : "mmc";
            e.type = e.type || types["/mnt/media_rw/" + volumeName(d.mount)] || "";
            return e;
        })
    };
}

// ------------------------------------------------------------- Syncthing

function emptySyncRaw() {
    return {
        running: true,
        pauseFile: false,
        error: "",
        folders: null,
        connections: null,
        status: {}
    };
}

// A folder doing something: Syncthing's own states for it.
var BUSY_FOLDER_STATES = ["scanning", "scan-waiting", "syncing", "sync-preparing", "sync-waiting", "cleaning", "clean-waiting", "starting"];

// What Syncthing is doing, from its own answers (see probe.sh):
//   paused   `matrix sync pause` left its file, or every folder or every
//            other device is paused -- syncthing-guard pauses them all on
//            mobile data
//   working  a folder is scanning or syncing
//   error    a folder has stopped on an error (a missing path, say)
//   idle     otherwise: up to date, or waiting for a device that is away
//   off      no syncthing runs
//   unknown  it runs, but its API did not answer
// Files that failed to sync leave a folder idle; they are counted
// (failedItems) rather than turned into a state.
function syncState(raw) {
    var out = {
        state: "unknown",
        folders: 0,
        pausedFolders: 0,
        busy: [],
        stopped: [],
        failedItems: 0,
        needFiles: 0,
        needBytes: 0,
        devices: 0,
        connected: 0,
        pausedDevices: 0,
        detail: raw.error || ""
    };
    if (!raw.running) {
        out.state = raw.pauseFile ? "paused" : "off";
        return out;
    }
    var folders = raw.folders || [];
    out.folders = folders.length;
    for (var i = 0; i < folders.length; i++) {
        var f = folders[i] || {};
        var name = f.label || f.id || "";
        if (f.paused) {
            out.pausedFolders++;
            continue;
        }
        var s = raw.status[f.id];
        if (!s)
            continue;
        if (BUSY_FOLDER_STATES.indexOf(s.state) >= 0)
            out.busy.push(name);
        else if (s.state === "error")
            out.stopped.push(name);
        out.failedItems += (s.pullErrors || s.errors || 0);
        out.needFiles += s.needFiles || 0;
        out.needBytes += s.needBytes || 0;
    }
    var conns = raw.connections || {};
    for (var id in conns) {
        out.devices++;
        if (conns[id].paused)
            out.pausedDevices++;
        else if (conns[id].connected)
            out.connected++;
    }
    if (raw.pauseFile || (out.folders > 0 && out.pausedFolders === out.folders) || (out.devices > 0 && out.pausedDevices === out.devices))
        out.state = "paused";
    else if (out.busy.length > 0)
        out.state = "working";
    else if (out.stopped.length > 0)
        out.state = "error";
    else if (raw.folders !== null)
        out.state = "idle";
    return out;
}

// ------------------------------------------------------------------ jobs

// "mx:job <kind> <percent|-> <name...>": one rsync or backup process running
// now. name is the sync-backup-manager unit it belongs to, "from another
// machine" for the far end of somebody's rsync, else what fct says it copies
// to, else the program.
function parseJobLine(rest) {
    var m = /^(\S+)\s+(\S+)\s*(.*)$/.exec(String(rest).trim());
    if (!m)
        return null;
    var p = num(m[2]);
    return {
        kind: m[1],
        percent: isFinite(p) ? clampPct(p) : -1,
        name: m[3] || ""
    };
}

var UNIT_PREFIX = "matrix-sync-backup-manager-";

// One kind of job ("rsync": the sync pairs, "backup": borg and restic) on
// one machine: how many sync-backup-manager has here, which run now, which
// wait to retry and which failed last time. A running job is a unit that is
// starting (a oneshot runs while "activating"), or a process of that kind
// that no running unit accounts for -- one started by hand, or the far end
// of another machine's sync. Progress is what fct knows of the hand-run
// ones.
function jobSummary(jobs, kind) {
    var prefix = UNIT_PREFIX + (kind === "rsync" ? "sync" : "backup") + "-";
    var units = (jobs && jobs.units || []).filter(function (u) {
        return u.unit.indexOf(prefix) === 0;
    });
    function pairName(unit) {
        return unit.slice(prefix.length).replace(/\.service$/, "");
    }
    var running = [];
    var retrying = [];
    var failed = [];
    for (var i = 0; i < units.length; i++) {
        var u = units[i];
        if (u.sub === "auto-restart")
            retrying.push(pairName(u.unit));
        else if (u.active === "activating" || u.active === "deactivating" || (u.active === "active" && u.sub === "running"))
            running.push(pairName(u.unit));
        else if (u.active === "failed")
            failed.push(pairName(u.unit));
    }
    var others = [];
    var procs = (jobs && jobs.running || []).filter(function (j) {
        return j.kind === kind;
    });
    for (var p = 0; p < procs.length; p++) {
        var j = procs[p];
        if (j.name.indexOf(prefix) === 0) {
            var n = pairName(j.name);
            if (running.indexOf(n) < 0)
                running.push(n);
            var r = retrying.indexOf(n);
            if (r >= 0)
                retrying.splice(r, 1);
        } else if (j.name.indexOf(UNIT_PREFIX) !== 0) {
            others.push(j);
        }
    }
    var known = others.filter(function (o) {
        return o.percent >= 0;
    });
    var pct = -1;
    if (known.length > 0 && running.length === 0) {
        pct = 0;
        for (var k = 0; k < known.length; k++)
            pct += known[k].percent;
        pct = pct / known.length;
    }
    return {
        configured: units.length,
        count: running.length + others.length,
        percent: pct,
        names: running.concat(others.map(function (o) {
            return o.name;
        })),
        retrying: retrying,
        failed: failed
    };
}

// --------------------------------------------------------------- the phone

// telephony.registry, one block per SIM slot. The slot shown is the one in
// service -- the one carrying data first. Also the call state: the busiest
// slot's (2 in a call, 1 ringing, 0 idle).
function parseTelephony(lines, props) {
    var slots = [];
    var cur = null;
    var call = 0;
    for (var i = 0; i < lines.length; i++) {
        var l = String(lines[i]);
        var m = /^Phone Id=(\d+)/.exec(l);
        if (m) {
            cur = {
                id: Number(m[1]),
                service: "",
                signal: "",
                dataState: -1
            };
            slots.push(cur);
        } else if (cur && l.indexOf("mServiceState=") === 0)
            cur.service = l;
        else if (cur && l.indexOf("mSignalStrength=") === 0)
            cur.signal = l;
        else if (cur && (m = /^mDataConnectionState=(-?\d+)/.exec(l)))
            cur.dataState = Number(m[1]);
        else if ((m = /^mCallState=(\d+)/.exec(l)))
            call = Math.max(call, Number(m[1]));
    }

    var best = null;
    for (var s = 0; s < slots.length; s++) {
        var slot = slots[s];
        slot.voiceIn = /mVoiceRegState=0\(/.test(slot.service);
        slot.dataIn = /mDataRegState=0\(/.test(slot.service);
        var rank = (slot.dataState === 2 ? 4 : 0) + (slot.dataIn ? 2 : 0) + (slot.voiceIn ? 1 : 0);
        if (!best || rank > best.rank)
            best = {
                slot: slot,
                rank: rank
            };
    }

    var callState = call === 2 ? "offhook" : (call === 1 ? "ringing" : "idle");
    var simStates = String(props["gsm.sim.state"] || "").split(",");
    var anySim = simStates.some(function (x) {
        return x === "LOADED" || x === "READY";
    });
    if (!best) {
        if (props["gsm.sim.state"] === undefined)
            return null;
        return {
            operator: "",
            rat: "",
            level: 0,
            dbm: NaN,
            inService: false,
            dataConnected: false,
            roaming: false,
            noSim: !anySim,
            call: callState
        };
    }

    var slot2 = best.slot;
    var op = field(slot2.service, "mOperatorAlphaLong") || field(slot2.service, "mOperatorAlphaShort");
    if (!op) {
        var ops = String(props["gsm.operator.alpha"] || "").split(",");
        op = ops[slot2.id] || ops.filter(function (x) {
            return x !== "";
        })[0] || "";
    }
    var sig = parseSignal(slot2.signal);
    var rat = ratName(slot2.service);
    if (sig.nrLevel > 0 && rat === "LTE")
        rat = "5G"; // NR next to LTE: 5G non-standalone
    var roamingProp = String(props["gsm.operator.isroaming"] || "").split(",")[slot2.id];
    return {
        operator: op,
        rat: slot2.voiceIn || slot2.dataIn ? rat : "",
        level: slot2.voiceIn || slot2.dataIn ? sig.level : 0,
        dbm: sig.dbm,
        inService: slot2.voiceIn || slot2.dataIn,
        dataConnected: slot2.dataState === 2,
        roaming: roamingProp === "true" || /roamingType=(DOMESTIC|INTERNATIONAL|UNKNOWN)/.test(slot2.service.replace(/roamingType=NOT_ROAMING/g, "")),
        noSim: !anySim,
        call: callState
    };
}

function field(text, name) {
    var m = new RegExp(name + "=([^,}]*)").exec(text || "");
    return m ? m[1].trim() : "";
}

// getRilDataRadioTechnology=14(LTE) -> "LTE"; 3G and 2G by their family.
function ratName(service) {
    var m = /getRilDataRadioTechnology=\d+\((\w+)\)/.exec(service) || /getRilVoiceRadioTechnology=\d+\((\w+)\)/.exec(service);
    var t = m ? m[1] : "";
    if (t === "Unknown" || t === "") {
        var v = /getRilVoiceRadioTechnology=\d+\((\w+)\)/.exec(service);
        t = v ? v[1] : "";
    }
    switch (t) {
    case "NR":
        return "5G";
    case "LTE":
    case "LTE_CA":
        return "LTE";
    case "HSPAP":
        return "H+";
    case "HSPA":
    case "HSDPA":
    case "HSUPA":
        return "H";
    case "UMTS":
    case "TD_SCDMA":
    case "EHRPD":
    case "EVDO_0":
    case "EVDO_A":
    case "EVDO_B":
        return "3G";
    case "EDGE":
        return "E";
    case "GPRS":
    case "GSM":
    case "1xRTT":
    case "IS95A":
    case "IS95B":
        return "2G";
    case "IWLAN":
        return "Wi-Fi calling";
    case "Unknown":
    case "":
        return "";
    default:
        return t;
    }
}

// The strength Android itself shows: the "primary" measurement's level
// (0-4) and its dBm.
function parseSignal(text) {
    var out = {
        level: 0,
        dbm: NaN,
        nrLevel: 0
    };
    if (!text)
        return out;
    var parts = {
        Lte: /mLte=CellSignalStrengthLte:[^,]*?rsrp=(-?\d+)[^,]*?level=(\d+)/,
        Nr: /mNr=CellSignalStrengthNr:\{[^}]*?ssRsrp = (-?\d+)[^}]*?level = (\d+)/,
        Wcdma: /mWcdma=CellSignalStrengthWcdma:[^,]*?rscp=(-?\d+)[^,]*?level=(\d+)/,
        Gsm: /mGsm=CellSignalStrengthGsm: rssi=(-?\d+)[^,]*?mLevel=(\d+)/
    };
    var found = {};
    for (var k in parts) {
        var m = parts[k].exec(text);
        if (m) {
            var d = Number(m[1]);
            found[k] = {
                level: Number(m[2]),
                dbm: d === UNSET ? NaN : d
            };
        }
    }
    if (found.Nr)
        out.nrLevel = found.Nr.level;
    var p = /primary=CellSignalStrength(\w+)/.exec(text);
    var pick = p && found[p[1]] ? found[p[1]] : null;
    if (!pick) {
        for (var key in found) {
            if (!pick || found[key].level > pick.level)
                pick = found[key];
        }
    }
    if (pick) {
        out.level = Math.max(0, Math.min(4, pick.level));
        out.dbm = pick.dbm;
    }
    return out;
}

// cmd wifi status: "Wifi is connected to "Home"", "WifiInfo: SSID: "Home", ..., RSSI: -48, ..."
function parseWifi(lines) {
    var text = lines.join("\n");
    var enabled = !/Wifi is disabled/.test(text);
    var m = /connected to "(.*)"/.exec(text) || /SSID: "(.*?)"/.exec(text);
    var rssi = /RSSI: (-?\d+)/.exec(text);
    var ssid = m ? m[1] : "";
    if (ssid === "<unknown ssid>")
        ssid = "";
    return {
        enabled: enabled,
        connected: enabled && ssid !== "",
        ssid: ssid,
        rssi: rssi ? Number(rssi[1]) : NaN
    };
}

// The bars Android draws for a Wi-Fi RSSI (0-4).
function wifiLevel(rssi) {
    if (!isFinite(rssi))
        return 0;
    if (rssi >= -55)
        return 4;
    if (rssi >= -66)
        return 3;
    if (rssi >= -77)
        return 2;
    if (rssi >= -88)
        return 1;
    return 0;
}

// The data policy: its cycle (start day, time and length) and its warning
// and limit, as Settings > Data usage sets them.
function parsePolicy(line) {
    if (!line)
        return null;
    var start = /cycleRule=RecurrenceRule\{start=(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(line);
    var period = /period=(P\w+)/.exec(line);
    var warn = /warningBytes=(-?\d+)/.exec(line);
    var limit = /limitBytes=(-?\d+)/.exec(line);
    return {
        day: start ? Number(start[3]) : 1,
        hour: start ? Number(start[4]) : 0,
        minute: start ? Number(start[5]) : 0,
        monthly: !period || period[1] === "P1M",
        warningBytes: warn && Number(warn[1]) > 0 ? Number(warn[1]) : 0,
        limitBytes: limit && Number(limit[1]) > 0 ? Number(limit[1]) : 0
    };
}

// The month day `day` in a given month, or its last day when the month is
// shorter: a cycle starting on the 31st starts on the 30th in April.
function _monthDay(year, month, day, hour, minute) {
    var last = new Date(year, month + 1, 0).getDate();
    return new Date(year, month, Math.min(day, last), hour, minute, 0, 0);
}

// When the current cycle began and ends, in this computer's time zone.
function cycleBounds(policy, nowMs) {
    var p = policy && policy.monthly ? policy : {
        day: 1,
        hour: 0,
        minute: 0
    };
    var now = new Date(nowMs);
    var start = _monthDay(now.getFullYear(), now.getMonth(), p.day, p.hour, p.minute);
    if (start.getTime() > nowMs)
        start = _monthDay(now.getFullYear(), now.getMonth() - 1, p.day, p.hour, p.minute);
    var end = _monthDay(start.getFullYear(), start.getMonth() + 1, p.day, p.hour, p.minute);
    return {
        start: start.getTime(),
        end: end.getTime()
    };
}

// Hourly rows of the counter -> what this cycle has used, and how much of
// what it may use: the phone's own limit, else its warning, else the
// allowance set in this plugin (allowanceBytes, 0 for none).
function dataUsage(rows, policy, nowMs, allowanceBytes) {
    var b = cycleBounds(policy, nowMs);
    var used = 0;
    for (var i = 0; i < rows.length; i++) {
        var ms = rows[i].st * 1000;
        if (ms >= b.start && ms < b.end)
            used += rows[i].rx + rows[i].tx;
    }
    var limit = policy ? policy.limitBytes : 0;
    var warning = policy ? policy.warningBytes : 0;
    var of = limit || warning || allowanceBytes || 0;
    return {
        start: b.start,
        end: b.end,
        used: used,
        limitBytes: limit,
        warningBytes: warning,
        ofBytes: of,
        ofWhat: limit ? "limit" : (warning ? "warning" : (allowanceBytes ? "allowance" : "")),
        percent: of > 0 ? clampPct(100 * used / of) : -1
    };
}

// Wi-Fi when the phone is on it, else mobile data when that carries the
// traffic, else nothing -- or airplane mode, which says why.
//
// uplink, the card the default route leaves by, is the surest word on it:
// wlan* and eth* are Wi-Fi and a cable, anything else (rmnet*, ccmni*,
// v4-rmnet*) mobile data -- the same test syncthing-guard makes. Without it
// (no `ip`, no root), what Wi-Fi and the modem say.
function networkKind(wifi, cell, airplane, uplink) {
    if (uplink)
        return /^(wlan|eth|swlan)/.test(uplink) ? "wifi" : "mobile";
    if (uplink === "")
        return airplane ? "airplane" : "none";
    if (wifi && wifi.connected)
        return "wifi";
    if (cell && cell.dataConnected)
        return "mobile";
    if (airplane)
        return "airplane";
    return "none";
}

// ------------------------------------------------------------------ state

function emptyState() {
    return {
        snapshots: 0,
        host: "",
        android: false,
        root: false,
        ncpu: 0,
        cpu: -1,
        gpu: -1,
        gpus: [],
        mem: null,
        swap: null,
        battery: null,
        ssh: null,
        disks: [],
        removable: [],
        storageKnown: false,
        sync: null,
        rsync: null,
        backup: null,
        cell: null,
        wifi: null,
        airplane: false,
        uplink: null,
        net: "",
        // the switches: mobile data on (true/false, null unknown), the
        // hotspot { on, ifaces }, and the serial adb knows the phone by
        dataOn: null,
        hotspot: null,
        serial: "",
        call: "",
        missed: -1,
        data: null,
        // the raw readings the next snapshot's rates are worked out from
        _cpu: null,
        _gpu: {},
        _drm: null,
        _units: [],
        _props: {},
        _policy: null,
        _dataRows: null
    };
}

function _copy(o) {
    var out = {};
    for (var k in o)
        out[k] = o[k];
    return out;
}

// What a machine looks like after one more snapshot. Rates come from this
// snapshot's last reading and the one before it -- in this snapshot (the
// first one takes two) or the previous one. Whatever this snapshot did not
// carry is kept from before. opts.dataAllowanceBytes: see dataUsage().
function advance(prev, snap, nowMs, opts) {
    var st = _copy(prev || emptyState());
    var o = opts || {};
    st.snapshots = (prev ? prev.snapshots : 0) + 1;
    if (snap.host)
        st.host = snap.host;
    if (snap.android !== null) {
        st.android = snap.android;
        st.root = snap.root;
    }
    if (snap.ncpu > 0)
        st.ncpu = snap.ncpu;

    // CPU
    if (snap.cpu.length > 0) {
        var a = snap.cpu.length >= 2 ? snap.cpu[snap.cpu.length - 2] : st._cpu;
        var c = cpuPercent(a, snap.cpu[snap.cpu.length - 1]);
        // A phone without root cannot read /proc/stat: the line is empty.
        st.cpu = c;
        st._cpu = snap.cpu[snap.cpu.length - 1];
    }

    // GPU: every source this machine has, and the busiest of them. An Intel
    // GPU's programs say what they kept it busy with; only when none of
    // them can be read is its time awake (RC6) used instead.
    var gpus = [];
    var gpuSamples = _copy(st._gpu);
    var engines = -1;
    if (snap.drm.length > 0) {
        var dLast = snap.drm[snap.drm.length - 1];
        engines = drmPercent(snap.drm.length >= 2 ? snap.drm[snap.drm.length - 2] : st._drm, dLast);
        st._drm = dLast;
    }
    for (var id in snap.gpuIdle) {
        var list = snap.gpuIdle[id];
        var last = list[list.length - 1];
        var before = list.length >= 2 ? list[list.length - 2] : gpuSamples[id];
        var g = engines >= 0 ? engines : gpuIdlePercent(before, last);
        gpuSamples[id] = last;
        if (g >= 0)
            gpus.push({
                id: id,
                percent: g
            });
    }
    for (var bid in snap.gpuBusy)
        gpus.push({
            id: bid,
            percent: clampPct(snap.gpuBusy[bid])
        });
    st._gpu = gpuSamples;
    if (gpus.length > 0 || Object.keys(snap.gpuIdle).length > 0) {
        st.gpus = gpus;
        st.gpu = gpus.reduce(function (m, x) {
            return Math.max(m, x.percent);
        }, -1);
    }

    // Memory and swap
    if (snap.mem) {
        var total = snap.mem.totalKb * 1024;
        var used = Math.max(0, snap.mem.totalKb - snap.mem.availKb) * 1024;
        st.mem = {
            total: total,
            used: used,
            percent: pctOf(used, total)
        };
        var sTotal = snap.mem.swapTotalKb * 1024;
        var sUsed = Math.max(0, snap.mem.swapTotalKb - snap.mem.swapFreeKb) * 1024;
        st.swap = {
            total: sTotal,
            used: sUsed,
            percent: sTotal > 0 ? pctOf(sUsed, sTotal) : -1
        };
    }

    // Battery: several (a laptop with two) are averaged; charging if one is.
    if (snap.batteries.length > 0) {
        var sum = 0;
        var charging = false;
        var full = true;
        for (var i = 0; i < snap.batteries.length; i++) {
            var bat = snap.batteries[i];
            sum += bat.level;
            if (bat.status === "Charging")
                charging = true;
            if (bat.status !== "Full")
                full = false;
        }
        st.battery = {
            level: clampPct(sum / snap.batteries.length),
            charging: charging,
            full: full,
            status: charging ? "charging" : (full ? "full" : (snap.batteries[0].status === "Not charging" ? "not charging" : "on battery"))
        };
    } else if (snap.seq === 0) {
        st.battery = null;
    }

    // ssh: everyone but this probe, and where they come from -- a machine
    // of the matrix by its name (opts.peerNames: address -> name).
    if (snap.ssh) {
        var other = Math.max(0, snap.ssh.notty - snap.ssh.self);
        var names = o.peerNames || {};
        var from = [];
        var peers = snap.sshPeers || [];
        for (var pi = 0; pi < peers.length; pi++) {
            var who = peers[pi] === "127.0.0.1" || peers[pi] === "::1" ? "this machine (or Tailscale)" : (names[peers[pi]] || peers[pi]);
            if (from.indexOf(who) < 0)
                from.push(who);
        }
        st.ssh = {
            total: snap.ssh.tty + other,
            tty: snap.ssh.tty,
            other: other,
            from: from
        };
    }

    if (snap.storage) {
        st.disks = snap.storage.disks;
        st.removable = snap.storage.removable;
        st.storageKnown = true;
    }
    if (snap.sync)
        st.sync = snap.sync;
    if (snap.jobs) {
        var jobs = snap.jobs;
        if (jobs.unitsSame)
            jobs = {
                units: st._units || [],
                running: jobs.running
            };
        st._units = jobs.units;
        st.rsync = jobSummary(jobs, "rsync");
        st.backup = jobSummary(jobs, "backup");
    }

    // The phone
    if (st.android) {
        var props = _copy(st._props);
        for (var p in snap.props)
            props[p] = snap.props[p];
        st._props = props;
        if (snap.tel.length > 0)
            st.cell = parseTelephony(snap.tel, props);
        if (snap.wifi.length > 0)
            st.wifi = parseWifi(snap.wifi);
        if (snap.settings.airplane !== undefined)
            st.airplane = snap.settings.airplane === "1";
        if (snap.settings.data === "0" || snap.settings.data === "1")
            st.dataOn = snap.settings.data === "1";
        if (snap.tether !== null)
            st.hotspot = {
                on: snap.tether.some(function (i) {
                    return /^(wlan|softap|ap_br|swlan)/.test(i);
                }),
                ifaces: snap.tether
            };
        st.serial = props["ro.serialno"] || st.serial;
        if (snap.uplink !== null)
            st.uplink = snap.uplink;
        if (snap.tel.length > 0 || snap.wifi.length > 0 || snap.uplink !== null)
            st.net = networkKind(st.wifi, st.cell, st.airplane, st.uplink);
        if (st.cell)
            st.call = st.cell.call;
        if (snap.missed !== null)
            st.missed = snap.missed;
        if (snap.dataRows !== null) {
            st._policy = parsePolicy(snap.policy);
            st._dataRows = snap.dataRows;
        }
        if (st._dataRows !== null)
            st.data = dataUsage(st._dataRows, st._policy, nowMs || Date.now(), o.dataAllowanceBytes || 0);
    }
    return st;
}

// ------------------------------------------------------------ classifying

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

// Why a machine's stream ended (or never started), from ssh's exit code and
// what it wrote to stderr. Exit code 91 is the local wrapper's: no ssh.
function classifyExit(code, stderr, gotSnapshots) {
    var err = stderr || "";
    var line;
    function v(state, detail) {
        return {
            state: state,
            detail: detail || ""
        };
    }
    if (code === 91)
        return v("error", "ssh is not installed on this machine");
    if (_matchLine(err, /REMOTE HOST IDENTIFICATION HAS CHANGED|host key for .* has changed/i))
        return v("hostkey", "the host key has CHANGED -- check why before trusting it");
    if (_matchLine(err, /Host key verification failed|host key is known for/i))
        return v("hostkey", "host key not known yet -- connect once to accept it");
    if ((line = _matchLine(err, /Permission denied|Too many authentication failures|Authentication failed/i)))
        return v("auth", line);
    if (_matchLine(err, /Could not resolve hostname|Name or service not known|Temporary failure in name resolution/i))
        return v("unreachable", "the name does not resolve");
    if (_matchLine(err, /Connection refused/i))
        return v("unreachable", "connection refused");
    if ((line = _matchLine(err, /No route to host|Network is unreachable|Host is unreachable|Network is down/i)))
        return v("unreachable", line);
    if (_matchLine(err, /timed out|Timeout, server/i))
        return v("unreachable", "timed out");
    if ((line = _matchLine(err, /Connection closed|Connection reset|kex_exchange_identification|banner exchange|Broken pipe/i)))
        return v("unreachable", line);
    if (gotSnapshots)
        return v("unreachable", "the connection ended");
    if (code === 255)
        return v("unreachable", _lastLine(err) || "ssh could not connect");
    return v("error", _lastLine(err) || ("the probe stopped (exit " + code + ")"));
}

// A machine that refused us is not retried on its own: a wrong key every
// minute is what fail2ban is for. A manual refresh tries again.
function holdsUntilManual(state) {
    return state === "auth" || state === "hostkey";
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

// The number under a bar: whole percent, "–" when unknown.
function pctLabel(p) {
    return isFinite(p) && p >= 0 ? String(Math.round(p)) : "–";
}

function percentText(p) {
    return isFinite(p) && p >= 0 ? Math.round(p) + "%" : "unknown";
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

// Up to three letters a narrow bar has room for: "nebuchadnezzar" -> "NEB".
function shortName(name) {
    var n = String(name || "").replace(/[^A-Za-z0-9]/g, "");
    return n.slice(0, 3).toUpperCase() || "?";
}

var STATE_LABELS = {
    online: "online",
    connecting: "connecting…",
    unreachable: "unreachable",
    auth: "auth failed",
    hostkey: "host key not trusted",
    error: "error",
    off: "not watched"
};

function stateLabel(state) {
    return STATE_LABELS[state] || state || "";
}

// ------------------------------------------------------------------ icons

var SIGNAL_ICONS = ["signal_cellular_0_bar", "signal_cellular_1_bar", "signal_cellular_2_bar", "signal_cellular_3_bar", "signal_cellular_4_bar"];

function signalIcon(cell, airplane) {
    if (airplane)
        return "airplanemode_active";
    if (!cell || cell.noSim)
        return "signal_cellular_nodata";
    if (!cell.inService)
        return "signal_cellular_off";
    return SIGNAL_ICONS[cell.level] || SIGNAL_ICONS[0];
}

var RAT_ICONS = {
    "5G": "5g",
    "LTE": "lte_mobiledata",
    "H+": "h_plus_mobiledata",
    "H": "h_mobiledata",
    "3G": "3g_mobiledata",
    "E": "e_mobiledata",
    "2G": "g_mobiledata"
};

// One icon for how the phone is online: Wi-Fi with its strength, mobile data
// with its kind (LTE, 5G...), or neither.
function networkIcon(st) {
    if (!st)
        return "wifi_off";
    switch (st.net) {
    case "wifi":
        var rssi = st.wifi ? st.wifi.rssi : NaN;
        if (!isFinite(rssi))
            return "wifi";
        return ["signal_wifi_0_bar", "wifi_1_bar", "wifi_2_bar", "wifi", "wifi"][wifiLevel(rssi)];
    case "mobile":
        return RAT_ICONS[st.cell ? st.cell.rat : ""] || "swap_vert";
    case "airplane":
        return "airplanemode_active";
    default:
        return "wifi_off";
    }
}

function callIcon(call) {
    if (call === "ringing")
        return "ring_volume";
    if (call === "offhook")
        return "phone_in_talk";
    return "call";
}

var SYNC_ICONS = {
    working: "sync",
    idle: "check",
    paused: "pause",
    error: "sync_problem",
    off: "sync_disabled",
    unknown: "question_mark"
};

function syncIcon(sync) {
    return SYNC_ICONS[sync ? sync.state : "unknown"] || "question_mark";
}

// --------------------------------------------------------------- tooltips
// What hovering each part of the bar says, in plain lines.

function _join(lines) {
    return lines.filter(function (l) {
        return l !== "" && l !== null && l !== undefined;
    }).join("\n");
}

function _list(names, max) {
    var n = max || 4;
    if (names.length <= n)
        return names.join(", ");
    return names.slice(0, n).join(", ") + " and " + (names.length - n) + " more";
}

function cpuTip(st) {
    if (!st || st.cpu < 0)
        return st && st.android && !st.root ? "CPU: unknown -- needs root on the phone" : "CPU: unknown";
    return "CPU " + percentText(st.cpu) + (st.ncpu > 0 ? " · " + st.ncpu + " cores" : "");
}

function gpuTip(st) {
    if (!st || st.gpus.length === 0)
        return st && st.snapshots > 0 ? "GPU: no usage figure on this machine" : "GPU: unknown";
    var lines = ["GPU " + percentText(st.gpu)];
    if (st.gpus.length > 1) {
        for (var i = 0; i < st.gpus.length; i++)
            lines.push(st.gpus[i].id + "  " + percentText(st.gpus[i].percent));
    }
    return _join(lines);
}

function memTip(st) {
    if (!st || !st.mem)
        return "Memory: unknown";
    return "Memory " + percentText(st.mem.percent) + " · " + pairText(st.mem.used, st.mem.total);
}

function swapTip(st) {
    if (!st || !st.swap)
        return "Swap: unknown";
    if (!(st.swap.total > 0))
        return "No swap";
    return "Swap " + percentText(st.swap.percent) + " · " + pairText(st.swap.used, st.swap.total);
}

function diskTip(d, title) {
    if (!d)
        return title + ": none";
    return _join([title + " · " + (d.label ? d.label + " · " : "") + d.mount + (d.type ? " (" + d.type + ")" : ""), percentText(d.percent) + " used · " + pairText(d.used, d.total) + " · " + bytesText(d.avail) + " free"]);
}

function batteryTip(b) {
    if (!b)
        return "No battery";
    return "Battery " + percentText(b.level) + " · " + b.status;
}

function sshTip(st) {
    var s = st ? st.ssh : null;
    if (!s)
        return "SSH connections: unknown";
    if (s.total === 0)
        return "No SSH connections";
    var parts = [];
    if (s.tty > 0)
        parts.push(s.tty + " with a terminal");
    if (s.other > 0)
        parts.push(s.other + " without (file copies, ssh-link, matrix)");
    return _join([s.total + " SSH connection" + (s.total === 1 ? "" : "s"), parts.join(", "), s.from && s.from.length ? "from " + _list(s.from) : ""]);
}

var SYNC_WORDS = {
    working: "working",
    idle: "idle",
    paused: "paused",
    error: "stopped on an error",
    off: "not running",
    unknown: "not answering"
};

function syncTip(st) {
    var s = st ? st.sync : null;
    if (!s)
        return "Syncthing: unknown";
    var lines = ["Syncthing " + (SYNC_WORDS[s.state] || s.state)];
    if (s.state === "working" && s.busy.length)
        lines.push(_list(s.busy));
    if (s.state === "error" && s.stopped.length)
        lines.push(_list(s.stopped));
    if (s.folders > 0)
        lines.push(s.folders + " folder" + (s.folders === 1 ? "" : "s") + (s.pausedFolders ? ", " + s.pausedFolders + " paused" : "") + (s.devices > 0 ? " · " + s.connected + " of " + s.devices + " devices connected" : ""));
    if (s.needFiles > 0)
        lines.push(s.needFiles + " file" + (s.needFiles === 1 ? "" : "s") + " to fetch (" + bytesText(s.needBytes) + ")");
    if (s.failedItems > 0)
        lines.push(s.failedItems + " item" + (s.failedItems === 1 ? "" : "s") + " failed to sync");
    if (s.detail)
        lines.push(s.detail);
    return _join(lines);
}

function jobTip(j, what, unitWord) {
    if (!j)
        return what + ": unknown";
    var lines = [what + ": " + (j.count > 0 ? j.count + " running" : "nothing running") + (j.configured > 0 ? " · " + j.configured + " " + unitWord + (j.configured === 1 ? "" : "s") : "")];
    if (j.names.length)
        lines.push(_list(j.names) + (j.percent >= 0 ? " · " + percentText(j.percent) : ""));
    if (j.failed.length)
        lines.push("failed last time: " + _list(j.failed));
    if (j.retrying.length)
        lines.push("waiting to retry: " + _list(j.retrying));
    return _join(lines);
}

var SIGNAL_WORDS = ["no signal", "weak", "fair", "good", "excellent"];

function signalTip(st) {
    if (!st)
        return "Signal: unknown";
    if (st.airplane)
        return "Airplane mode";
    var c = st.cell;
    if (!c)
        return st.root ? "Signal: unknown" : "Signal: needs root on the phone";
    if (c.noSim)
        return "No SIM";
    if (!c.inService)
        return "No service" + (c.operator ? " · " + c.operator : "");
    return _join([[c.operator, c.rat, SIGNAL_WORDS[c.level] || ""].filter(function (x) {
                return x;
            }).join(" · ") + (isFinite(c.dbm) ? " (" + c.dbm + " dBm)" : ""), c.roaming ? "roaming" : ""]);
}

function networkTip(st) {
    if (!st)
        return "Network: unknown";
    switch (st.net) {
    case "wifi":
        var w = st.wifi;
        return "Wi-Fi" + (w && w.ssid ? ": " + w.ssid : "") + (w && isFinite(w.rssi) ? " (" + w.rssi + " dBm)" : "");
    case "mobile":
        return "Mobile data" + (st.cell && st.cell.rat ? " (" + st.cell.rat + ")" : "") + (st.cell && st.cell.operator ? " · " + st.cell.operator : "");
    case "airplane":
        return "Airplane mode: offline";
    case "none":
        return "Offline: no Wi-Fi, no mobile data";
    default:
        return "Network: unknown";
    }
}

function callTip(st) {
    if (!st || !st.call)
        return st && !st.root ? "Calls: needs root on the phone" : "Calls: unknown";
    var head = st.call === "ringing" ? "Ringing" : (st.call === "offhook" ? "In a call" : "No call");
    var missed = st.missed > 0 ? st.missed + " missed call" + (st.missed === 1 ? "" : "s") : (st.missed === 0 ? "no missed calls" : "");
    return _join([head, missed]);
}

// ------------------------------------------------------------- switches
// A phone's Wi-Fi, mobile data and hotspot, switched from the bar.

var SWITCHES = ["wifi", "data", "hotspot"];
var SWITCH_NAMES = {
    wifi: "Wi-Fi",
    data: "Mobile data",
    hotspot: "Hotspot"
};

// Whether it is on now: true, false, or null when the phone has not said.
function switchState(st, what) {
    if (!st)
        return null;
    switch (what) {
    case "wifi":
        return st.wifi ? st.wifi.enabled : null;
    case "data":
        return st.dataOn;
    case "hotspot":
        return st.hotspot ? st.hotspot.on : null;
    }
    return null;
}

function switchIcon(what, on) {
    switch (what) {
    case "wifi":
        return on === false ? "wifi_off" : "wifi";
    case "data":
        return on === false ? "mobiledata_off" : "swap_vert";
    case "hotspot":
        return on === false ? "portable_wifi_off" : "wifi_tethering";
    }
    return "toggle_off";
}

// What switching it would cost, when that is losing the phone: the bar
// reads it over the network it has, and switching off the one it uses
// leaves nothing to switch it back on with but a USB cable. "" when
// nothing is lost.
function switchRisk(st, what, wantOn) {
    if (!st || wantOn)
        return "";
    var wifiUp = st.net === "wifi";
    var mobileUp = st.net === "mobile";
    if (what === "wifi" && wifiUp && !(st.dataOn && st.cell && st.cell.inService))
        return "Wi-Fi is the phone's only network: without it the bar loses the phone, and only adb over USB can switch it back on.";
    if (what === "data" && mobileUp && !(st.wifi && st.wifi.connected))
        return "Mobile data is the phone's only network: without it the bar loses the phone, and only adb over USB can switch it back on.";
    return "";
}

// sw: the service's word on this switch -- { want, error, via } or null.
function switchTip(st, what, sw, armedRisk) {
    var name = SWITCH_NAMES[what] || what;
    var on = switchState(st, what);
    if (armedRisk)
        return _join([armedRisk, "Click again to switch " + name + " off anyway."]);
    if (sw && sw.error)
        return _join(["Could not switch " + name + " " + (sw.want ? "on" : "off"), sw.error]);
    if (sw && sw.want !== undefined && sw.want !== on)
        return "Switching " + name + " " + (sw.want ? "on" : "off") + "…";
    if (on === null)
        return name + ": not known yet";
    var head = name + ": " + (on ? "on" : "off");
    if (what === "wifi" && on && st.wifi && st.wifi.ssid)
        head += " · " + st.wifi.ssid;
    if (what === "data" && on && st.net === "mobile")
        head += " · in use";
    if (what === "hotspot" && on && st.hotspot.ifaces.length)
        head += " · " + st.hotspot.ifaces.join(", ");
    return _join([head, "Click to switch it " + (on ? "off" : "on")]);
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function dayText(ms) {
    var d = new Date(ms);
    return d.getDate() + " " + MONTHS[d.getMonth()];
}

function dataTip(st) {
    var d = st ? st.data : null;
    if (!d)
        return st && !st.root ? "Mobile data: needs root on the phone" : "Mobile data: not read yet";
    var lines = ["Mobile data " + bytesText(d.used) + (d.ofBytes > 0 ? " of " + bytesText(d.ofBytes) + " (" + d.ofWhat + ") · " + percentText(d.percent) : "")];
    lines.push("this cycle, since " + dayText(d.start));
    if (!(d.ofBytes > 0))
        lines.push("No limit or warning is set on the phone: set an allowance in Matrix Bar's settings for a percentage");
    return _join(lines);
}

function hostTip(h, r, nowMs) {
    var lines = [h.name + (h.self ? " · this machine" : "") + (h.android ? " · phone" : "")];
    if (!r)
        lines.push("not read yet");
    else {
        lines.push(stateLabel(r.state) + (r.detail ? ": " + r.detail : ""));
        if (r.atMs && r.state !== "online")
            lines.push("last read " + agoText(r.atMs, nowMs));
    }
    lines.push("click: fold or unfold · right-click: connect again");
    return _join(lines);
}
