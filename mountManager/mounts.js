.pragma library

// Pure helpers: lsblk's tree in, one flat list of rows out, plus the rules for
// what may be done to each row. Side-effect free so it can be exercised
// outside quickshell against real `lsblk -b -J` output.

function num(v) {
    if (typeof v === "number")
        return isFinite(v) ? v : NaN;
    if (typeof v !== "string")
        return NaN;
    var n = parseFloat(v.replace(",", "."));
    return isFinite(n) ? n : NaN;
}

function str(v) {
    return v === undefined || v === null ? "" : String(v);
}

function sizeText(bytes) {
    var n = num(bytes);
    if (!isFinite(n) || n < 0)
        return "";
    var units = ["B", "KB", "MB", "GB", "TB", "PB"];
    var i = 0;
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    var digits = i === 0 ? 0 : (n < 10 ? 1 : 0);
    return n.toFixed(digits) + " " + units[i];
}

function percentNum(v) {
    var n = num(String(v).replace("%", ""));
    return isFinite(n) ? n : -1;
}

// Where a hand-mounted volume is allowed to live. A filesystem mounted
// anywhere else is part of the running system, not something to detach from a
// bar popout.
var USER_MOUNT_ROOTS = ["/run/media/", "/media/", "/mnt/"];

function isUserMount(mountpoint) {
    for (var i = 0; i < USER_MOUNT_ROOTS.length; i++)
        if (mountpoint.indexOf(USER_MOUNT_ROOTS[i]) === 0)
            return true;
    return false;
}

// Filesystem types that are a container for something else, not a thing to
// mount. Trying to mount one is an error message, so no button is offered.
var CONTAINER_FS = ["crypto_LUKS", "LVM2_member", "linux_raid_member", "zfs_member", "bcache", "DDF_raid_member", "isw_raid_member"];

function isContainer(fstype) {
    return CONTAINER_FS.indexOf(fstype) >= 0;
}

function mountpointsOf(node) {
    var list = [];
    var mps = node.mountpoints;
    if (Array.isArray(mps)) {
        for (var i = 0; i < mps.length; i++)
            if (mps[i])
                list.push(String(mps[i]));
    } else if (node.mountpoint) {
        // Older util-linux only has the singular column.
        list.push(String(node.mountpoint));
    }
    // Shortest first, so a filesystem mounted at both / and /nix/store leads
    // with the one that says what it is.
    list.sort(function (a, b) {
        return a.length - b.length;
    });
    return list;
}

function iconFor(row) {
    if (row.locked)
        return "lock";
    if (row.swap)
        return "memory";
    if (row.transport === "usb")
        return "usb";
    if (row.transport === "mmc" || row.kind === "mmc")
        return "sd_card";
    if (row.kind === "crypt")
        return "lock_open";
    if (row.kind === "loop")
        return "layers";
    if (row.optical)
        return "album";
    return "hard_drive";
}

// The name a person would use for it: its label first, then what the disk
// calls itself, then the kernel name as a last resort. The disk's model only
// stands in for a removable volume, where "SanDisk Ultra" is what is written
// on the thing in your hand; on an unlabelled internal partition it would name
// the whole drive and say nothing about which partition this is.
function titleOf(row) {
    if (row.label)
        return row.label;
    if (row.partlabel)
        return row.partlabel;
    if (row.kind === "crypt" && row.parentLabel)
        return row.parentLabel;
    if (row.model && (row.removable || row.bareDisk))
        return row.model;
    return row.name;
}

function subtitleOf(row) {
    if (row.locked)
        return "locked";
    if (row.swap)
        return "swap";
    if (row.mounted)
        return row.mountpoints.join("  ·  ");
    if (!row.fstype)
        return "no filesystem";
    return "not mounted";
}

function detailOf(row) {
    var parts = [];
    if (row.sizeBytes > 0)
        parts.push(sizeText(row.sizeBytes));
    if (row.fstype && !row.locked)
        parts.push(row.fstype);
    if (row.mounted && row.usePercent >= 0)
        parts.push(row.usePercent + "% used");
    else if (row.mounted && isFinite(row.availBytes))
        parts.push(sizeText(row.availBytes) + " free");
    if (row.readOnly)
        parts.push("read-only");
    return parts.join(" · ");
}

function unlockHint(row) {
    return "udisksctl unlock -b " + row.path;
}

// One row per thing that holds, or could hold, a filesystem: partitions,
// unlocked containers, and whole disks that were formatted without a
// partition table (every USB stick sold pre-formatted).
function parseDevices(raw, opts) {
    opts = opts || {};
    var showLoop = opts.showLoop === true;
    var out = {
        rows: [],
        error: ""
    };

    var data;
    try {
        data = JSON.parse(raw);
    } catch (e) {
        out.error = "could not read the device list";
        return out;
    }
    if (!data || !Array.isArray(data.blockdevices)) {
        out.error = "no devices reported";
        return out;
    }

    function visit(node, disk, parent) {
        var kind = str(node.type);
        var isDisk = kind === "disk" || kind === "loop";
        var top = isDisk ? node : disk;
        var children = Array.isArray(node.children) ? node.children : [];
        var fstype = str(node.fstype);
        var mountpoints = mountpointsOf(node);
        var swap = mountpoints.indexOf("[SWAP]") >= 0 || fstype === "swap";
        var mounted = mountpoints.length > 0 && !swap;
        // A LUKS partition with no child is a locked one: unlocking is what
        // creates the mapper device underneath it.
        var locked = isContainer(fstype) && children.length === 0;
        var removable = (top && (top.rm === true || top.hotplug === true)) || node.rm === true || node.hotplug === true;
        var transport = str(top && top.tran ? top.tran : node.tran);
        var mountpoint = mounted ? mountpoints[0] : "";

        // An unlocked container's own row would say "crypto_LUKS, not mounted"
        // forever, next to the child row that holds the actual filesystem. The
        // child is the answer; the container is plumbing. A LOCKED one still
        // gets a row, because "there is 17 GB here and it is locked" is
        // something worth seeing.
        var unlockedContainer = isContainer(fstype) && children.length > 0;

        var row = {
            key: str(node.path) || str(node.name),
            name: str(node.name),
            path: str(node.path) || ("/dev/" + str(node.name)),
            kind: kind,
            label: str(node.label),
            partlabel: str(node.partlabel),
            model: str(top && top.model ? top.model : node.model),
            transport: transport,
            diskPath: top ? (str(top.path) || ("/dev/" + str(top.name))) : "",
            diskName: top ? str(top.name) : "",
            parentName: parent ? str(parent.name) : "",
            // A mapper device is named luks-<uuid>, which names nothing. The
            // partition it came from usually carries the label someone chose.
            parentLabel: parent ? (str(parent.partlabel) || str(parent.label)) : "",
            fstype: fstype,
            sizeBytes: num(node.size),
            availBytes: num(node.fsavail),
            usedBytes: num(node.fsused),
            usePercent: percentNum(node["fsuse%"]),
            mountpoints: mountpoints,
            mountpoint: mountpoint,
            mounted: mounted,
            swap: swap,
            locked: locked,
            readOnly: node.ro === true,
            removable: removable === true,
            optical: kind === "rom" || str(node.tran) === "sata" && fstype === "iso9660"
        };

        // A mount that is not removable and not under a user mount root is the
        // running system: /, /nix/store, /boot. It is listed, because "what is
        // mounted" includes it, but nothing here offers to unmount it.
        row.system = row.mounted && !row.removable && !isUserMount(mountpoint);
        row.canUnmount = row.mounted && !row.system && !row.swap;
        row.canMount = !row.mounted && !row.swap && !row.locked && !!fstype && !isContainer(fstype) && !row.readOnly;
        row.canEject = row.removable && !!row.diskPath;

        // A disk is only a row of its own when it carries the filesystem
        // itself; otherwise its partitions are the rows and it is just their
        // heading.
        var isBareDisk = isDisk && children.length === 0;
        row.bareDisk = isBareDisk;
        var include = !isDisk || isBareDisk;
        if (kind === "loop" && !showLoop)
            include = false;
        if (unlockedContainer)
            include = false;
        if (include && (fstype || mounted || locked || isBareDisk))
            out.rows.push(row);

        for (var i = 0; i < children.length; i++)
            visit(children[i], top, node);
    }

    for (var j = 0; j < data.blockdevices.length; j++)
        visit(data.blockdevices[j], null, null);

    return out;
}

// Removable first — that is the list someone opens this for — then everything
// else in the order lsblk reported it.
function groupRows(rows) {
    var removable = [];
    var internal = [];
    for (var i = 0; i < rows.length; i++) {
        if (rows[i].removable)
            removable.push(rows[i]);
        else
            internal.push(rows[i]);
    }
    return {
        removable: removable,
        internal: internal
    };
}

function summarize(rows) {
    var s = {
        total: rows.length,
        mounted: 0,
        removable: 0,
        removableMounted: 0,
        mountable: 0,
        locked: 0
    };
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        if (r.mounted)
            s.mounted++;
        if (r.removable) {
            s.removable++;
            if (r.mounted)
                s.removableMounted++;
        }
        if (r.canMount)
            s.mountable++;
        if (r.locked)
            s.locked++;
    }
    return s;
}
