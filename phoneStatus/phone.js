.pragma library

// Reading what scripts/remote.sh prints, and the words and numbers the
// pill and the popout show. Pure functions, so tests/tst_phone.qml can check
// them against real probe output.

var UNSET = 2147483647; // what Android prints for "no value"

function num(v) {
    var n = Number(v);
    return isFinite(n) ? n : NaN;
}

// ------------------------------------------------------------------ reading

function emptyResult() {
    return {
        begun: false,
        complete: false,
        root: false,
        nowSec: 0,
        uptimeSec: NaN,
        props: {},
        settings: {},
        hasMpv: false,
        battery: null,
        cell: null,
        wifi: null,
        hotspot: null,
        storage: null,
        data: null,
        notifications: [],
        media: null,
        photos: []
    };
}

// The whole probe output -> one result. `nowMs` is this computer's clock,
// for the data cycle; the phone's own is in result.nowSec.
function parseProbe(text, nowMs) {
    var r = emptyResult();
    var lines = String(text || "").split("\n");
    var battery = {};
    var sys = {};
    var tel = [];
    var wifiLines = [];
    var tethers = [];
    var dataRows = [];
    var policy = "";
    var notifs = [];
    var sessions = [];

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/\r$/, "");
        if (line.indexOf("ps:") !== 0)
            continue;
        var body = line.slice(3);
        var tab = body.indexOf("\t");
        var sp = body.indexOf(" ");
        var cut = tab >= 0 && (sp < 0 || tab < sp) ? tab : sp;
        var tag = cut >= 0 ? body.slice(0, cut) : body;
        var rest = cut >= 0 ? body.slice(cut + 1) : "";

        switch (tag) {
        case "begin":
            r.begun = true;
            break;
        case "end":
            r.complete = true;
            break;
        case "now":
            r.nowSec = num(rest);
            break;
        case "uptime":
            r.uptimeSec = num(rest);
            break;
        case "root":
            r.root = rest.trim() === "1";
            break;
        case "has":
            if (rest.trim() === "mpv")
                r.hasMpv = true;
            break;
        case "prop":
            var ps = rest.indexOf(" ");
            if (ps < 0)
                r.props[rest] = "";
            else
                r.props[rest.slice(0, ps)] = rest.slice(ps + 1).trim();
            break;
        case "setting":
            var ss = rest.split(" ");
            r.settings[ss[0]] = (ss[1] || "").trim();
            break;
        case "battery":
            var c = rest.indexOf(":");
            if (c > 0)
                battery[rest.slice(0, c).trim()] = rest.slice(c + 1).trim();
            break;
        case "sys":
            var sy = rest.split(" ");
            sys[sy[0]] = sy.slice(1).join(" ");
            break;
        case "tel":
            tel.push(rest);
            break;
        case "wifi":
            wifiLines.push(rest);
            break;
        case "tether":
            var tp = rest.split(" ");
            tethers.push({
                iface: tp[0],
                clients: num(tp[1]) || 0
            });
            break;
        case "df":
            r.storage = parseDf(rest);
            break;
        case "policy":
            policy = rest;
            break;
        case "data":
            var dp = rest.split(" ");
            dataRows.push({
                st: num(dp[0]),
                rx: num(dp[1]) || 0,
                tx: num(dp[2]) || 0
            });
            break;
        case "notif":
            notifs.push(rest.split("\t"));
            break;
        case "media":
            sessions.push(rest.split("\t"));
            break;
        case "photo":
            if (rest.trim() !== "")
                r.photos.push(rest.trim());
            break;
        }
    }

    r.battery = Object.keys(battery).length > 0 ? parseBattery(battery) : parseSysBattery(sys);
    r.cell = parseTelephony(tel, r.props);
    r.wifi = wifiLines.length > 0 ? parseWifi(wifiLines) : null;
    r.hotspot = r.root ? {
        on: tethers.length > 0,
        clients: tethers.reduce(function (a, t) {
            return a + t.clients;
        }, 0)
    } : null;
    if (r.root)
        r.data = dataUsage(dataRows, parsePolicy(policy), nowMs || Date.now());
    r.notifications = parseNotifications(notifs);
    r.media = pickMedia(sessions);
    return r;
}

// dumpsys battery: "level: 99", "status: 2", "temperature: 322", ...
function parseBattery(b) {
    var plugged = "";
    if (b["AC powered"] === "true")
        plugged = "AC";
    else if (b["USB powered"] === "true")
        plugged = "USB";
    else if (b["Wireless powered"] === "true")
        plugged = "wireless";
    else if (b["Dock powered"] === "true")
        plugged = "dock";
    var level = num(b.level), scale = num(b.scale);
    if (isFinite(scale) && scale > 0 && scale !== 100)
        level = Math.round(level * 100 / scale);
    var temp = num(b.temperature);
    var design = num(b["Design capacity"]), max = num(b["Maximum capacity"]);
    return {
        level: level,
        state: batteryState(num(b.status)),
        plugged: plugged,
        tempC: isFinite(temp) ? temp / 10 : NaN,
        voltage: num(b.voltage) / 1000,
        health: batteryHealth(num(b.health)),
        // How much of what it held new it still holds.
        wear: isFinite(design) && design > 0 && isFinite(max) && max > 0 ? Math.round(max * 100 / design) : NaN
    };
}

// Without root, what /sys/class/power_supply/battery gives.
function parseSysBattery(sys) {
    if (sys.capacity === undefined)
        return null;
    var st = (sys.status || "").toLowerCase();
    return {
        level: num(sys.capacity),
        state: st === "charging" ? "charging" : (st === "full" ? "full" : (st === "not charging" ? "not charging" : "on battery")),
        plugged: "",
        tempC: NaN,
        voltage: NaN,
        health: "",
        wear: NaN
    };
}

function batteryState(status) {
    switch (status) {
    case 2:
        return "charging";
    case 3:
        return "on battery";
    case 4:
        return "not charging";
    case 5:
        return "full";
    default:
        return "";
    }
}

function batteryHealth(h) {
    switch (h) {
    case 2:
        return "good";
    case 3:
        return "overheating";
    case 4:
        return "dead";
    case 5:
        return "over voltage";
    case 6:
        return "failing";
    case 7:
        return "cold";
    default:
        return "";
    }
}

// telephony.registry, one block per SIM slot. The slot shown is the one in
// service -- the one carrying data first.
function parseTelephony(lines, props) {
    var slots = [];
    var cur = null;
    for (var i = 0; i < lines.length; i++) {
        var l = lines[i];
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
            noSim: !anySim
        };
    }

    var slot = best.slot;
    var op = field(slot.service, "mOperatorAlphaLong") || field(slot.service, "mOperatorAlphaShort");
    if (!op) {
        var ops = String(props["gsm.operator.alpha"] || "").split(",");
        op = ops[slot.id] || ops.filter(function (x) {
            return x !== "";
        })[0] || "";
    }
    var sig = parseSignal(slot.signal);
    var rat = ratName(slot.service);
    if (sig.nrLevel > 0 && rat === "LTE")
        rat = "5G"; // NR next to LTE: 5G non-standalone
    var roamingProp = String(props["gsm.operator.isroaming"] || "").split(",")[slot.id];
    return {
        operator: op,
        rat: slot.voiceIn || slot.dataIn ? rat : "",
        level: slot.voiceIn || slot.dataIn ? sig.level : 0,
        dbm: sig.dbm,
        inService: slot.voiceIn || slot.dataIn,
        dataConnected: slot.dataState === 2,
        roaming: roamingProp === "true" || /roamingType=(DOMESTIC|INTERNATIONAL|UNKNOWN)/.test(slot.service.replace(/roamingType=NOT_ROAMING/g, "")),
        noSim: !anySim
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
        Lte: {
            re: /mLte=CellSignalStrengthLte:[^,]*?rsrp=(-?\d+)[^,]*?level=(\d+)/,
            dbm: 1,
            lvl: 2
        },
        Nr: {
            re: /mNr=CellSignalStrengthNr:\{[^}]*?ssRsrp = (-?\d+)[^}]*?level = (\d+)/,
            dbm: 1,
            lvl: 2
        },
        Wcdma: {
            re: /mWcdma=CellSignalStrengthWcdma:[^,]*?rscp=(-?\d+)[^,]*?level=(\d+)/,
            dbm: 1,
            lvl: 2
        },
        Gsm: {
            re: /mGsm=CellSignalStrengthGsm: rssi=(-?\d+)[^,]*?mLevel=(\d+)/,
            dbm: 1,
            lvl: 2
        }
    };
    var found = {};
    for (var k in parts) {
        var m = parts[k].re.exec(text);
        if (m) {
            var d = Number(m[parts[k].dbm]);
            found[k] = {
                level: Number(m[parts[k].lvl]),
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

// df -k /data: device, 1K blocks, used, available, use%, mount.
function parseDf(rest) {
    var f = String(rest).trim().split(/\s+/);
    if (f.length < 4)
        return null;
    var total = num(f[1]) * 1024, used = num(f[2]) * 1024;
    if (!isFinite(total) || total <= 0)
        return null;
    return {
        total: total,
        used: used,
        fraction: used / total
    };
}

// ------------------------------------------------------------- mobile data

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

// Hourly rows of the counter -> this cycle, today, and one total per day of
// the cycle.
function dataUsage(rows, policy, nowMs) {
    var b = cycleBounds(policy, nowMs);
    var today = new Date(nowMs);
    today.setHours(0, 0, 0, 0);
    var used = 0, todayBytes = 0;
    var days = {};
    for (var i = 0; i < rows.length; i++) {
        var ms = rows[i].st * 1000;
        var bytes = rows[i].rx + rows[i].tx;
        if (ms >= b.start && ms < b.end) {
            used += bytes;
            var d = new Date(ms);
            d.setHours(0, 0, 0, 0);
            days[d.getTime()] = (days[d.getTime()] || 0) + bytes;
        }
        if (ms >= today.getTime())
            todayBytes += bytes;
    }
    var perDay = [];
    for (var t = new Date(b.start); t.getTime() < b.end && t.getTime() <= nowMs; t.setDate(t.getDate() + 1)) {
        var key = new Date(t.getFullYear(), t.getMonth(), t.getDate()).getTime();
        perDay.push({
            day: key,
            bytes: days[key] || 0
        });
    }
    return {
        start: b.start,
        end: b.end,
        used: used,
        today: todayBytes,
        warningBytes: policy ? policy.warningBytes : 0,
        limitBytes: policy ? policy.limitBytes : 0,
        fromPolicy: !!(policy && policy.monthly),
        days: perDay
    };
}

// ------------------------------------------------------------ notifications

// The apps whose package names say little. Everything else gets a name made
// from its package: "io.heckel.ntfy" -> "Ntfy".
var APP_NAMES = {
    "android": "Android",
    "com.android.systemui": "System",
    "com.android.phone": "Phone",
    "com.android.server.telecom": "Phone",
    "com.android.dialer": "Phone",
    "com.google.android.dialer": "Phone",
    "com.android.messaging": "Messages",
    "com.google.android.apps.messaging": "Messages",
    "com.android.mms": "Messages",
    "org.lineageos.jelly": "Browser",
    "com.android.vending": "Play Store",
    "com.google.android.gm": "Gmail",
    "com.google.android.youtube": "YouTube",
    "com.google.android.apps.photos": "Photos",
    "com.whatsapp": "WhatsApp",
    "com.whatsapp.w4b": "WhatsApp Business",
    "org.telegram.messenger": "Telegram",
    "org.thunderdog.challegram": "Telegram X",
    "org.thoughtcrime.securesms": "Signal",
    "io.element.android.x": "Element",
    "im.vector.app": "Element",
    "org.kde.kdeconnect_tp": "KDE Connect",
    "com.termux": "Termux",
    "io.heckel.ntfy": "ntfy",
    "org.mozilla.firefox": "Firefox",
    "org.mozilla.fennec_fdroid": "Fennec",
    "com.android.chrome": "Chrome",
    "com.instagram.android": "Instagram",
    "com.discord": "Discord",
    "com.spotify.music": "Spotify",
    "org.videolan.vlc": "VLC",
    "com.android.deskclock": "Clock",
    "com.google.android.deskclock": "Clock",
    "com.android.calendar": "Calendar",
    "org.fossify.messages": "Messages",
    "org.fossify.phone": "Phone",
    "eu.faircode.email": "FairEmail",
    "com.beemdevelopment.aegis": "Aegis"
};

var _NOISE = {
    com: 1,
    org: 1,
    io: 1,
    net: 1,
    dev: 1,
    app: 1,
    apps: 1,
    android: 1,
    google: 1,
    mobile: 1,
    client: 1,
    x: 1,
    tp: 1,
    "free": 1,
    lite: 1
};

function appName(pkg) {
    if (!pkg)
        return "";
    if (APP_NAMES[pkg])
        return APP_NAMES[pkg];
    var parts = pkg.split(".").map(function (p) {
        return p.replace(/_.*$/, "");
    }).filter(function (p) {
        return p !== "" && !_NOISE[p.toLowerCase()];
    });
    // The last meaningful part, unless it is a generic word like "manager".
    var name = parts.length > 0 ? parts[parts.length - 1] : pkg;
    if (parts.length > 1 && /^(manager|main|mobile|launcher|service|messenger|ui)$/i.test(name))
        name = parts[parts.length - 2] + " " + name;
    return name.charAt(0).toUpperCase() + name.slice(1);
}

// The rows of remote.sh's notification dump -> what is on the phone's
// notification shade: no group summaries (each message is there on its own),
// newest first. Ongoing ones -- a running service, a download -- are kept but
// marked, for the popout to fold away.
function parseNotifications(rows) {
    var out = [];
    for (var i = 0; i < rows.length; i++) {
        var f = rows[i];
        var flags = f[2] || "";
        if (/GROUP_SUMMARY/.test(flags))
            continue;
        var title = clean(f[4]), text = clean(f[5]), sub = clean(f[6]), big = clean(f[7]);
        if (title === "" && text === "" && big === "")
            continue;
        out.push({
            pkg: f[0],
            app: appName(f[0]),
            when: num(f[1]) || 0,
            ongoing: /ONGOING_EVENT|NO_CLEAR|FOREGROUND_SERVICE/.test(flags),
            category: f[3] || "",
            title: title,
            text: text !== "" ? text : big,
            subText: sub
        });
    }
    out.sort(function (a, b) {
        return b.when - a.when;
    });
    return out;
}

function clean(s) {
    s = String(s || "").trim();
    return s === "null" ? "" : s;
}

// ------------------------------------------------------------------- media

// PlaybackState: "PlaybackState {state=PLAYING(3)" or "PlaybackState {state=3".
function playbackState(text) {
    var m = /state=(?:[A-Z_]+\()?(\d+)/.exec(text || "");
    return m ? Number(m[1]) : 0;
}

// The session to show: one that is playing, else the newest active one with
// something loaded. The phone app's call session never has metadata.
function pickMedia(sessions) {
    var best = null;
    for (var i = 0; i < sessions.length; i++) {
        var s = sessions[i];
        var desc = clean(s[3]);
        if (desc === "" || desc === "null, null, null")
            continue;
        var state = playbackState(s[2]);
        var parts = desc.split(", ").map(function (p) {
            return p === "null" ? "" : p;
        });
        var item = {
            pkg: s[0],
            app: appName(s[0]),
            playing: state === 3,
            paused: state === 2,
            title: parts[0] || "",
            artist: parts[1] || "",
            album: parts.slice(2).join(", ")
        };
        if (item.playing)
            return item;
        if (!best && s[1] === "true")
            best = item;
    }
    return best;
}

// -------------------------------------------------------------- ssh results

// What ssh's failure means, from its exit code and stderr -- the same reading
// as Host Status.
function classify(code, stderr, timedOut) {
    var err = String(stderr || "");
    if (timedOut)
        return {
            state: "unreachable",
            detail: "no answer in time"
        };
    if (code === 91)
        return {
            state: "error",
            detail: "ssh is not installed on this computer"
        };
    var rules = [[/REMOTE HOST IDENTIFICATION HAS CHANGED/i, "hostkey", "the host key has CHANGED — check why before trusting it"], [/Host key verification failed/i, "hostkey", "host key not known yet — connect once to accept it"], [/Permission denied|Too many authentication failures/i, "auth", "the key was refused"], [/Could not resolve hostname|Name or service not known|Temporary failure in name resolution/i, "unreachable", "the name does not resolve"], [/Connection refused/i, "unreachable", "connection refused — is sshd running in Termux?"], [/No route to host|Network is unreachable|Host is unreachable/i, "unreachable", "no route to the phone"], [/timed out/i, "unreachable", "timed out"], [/Connection closed|Connection reset/i, "unreachable", "the connection was closed"]];
    for (var i = 0; i < rules.length; i++) {
        if (rules[i][0].test(err))
            return {
                state: rules[i][1],
                detail: rules[i][2]
            };
    }
    if (code === 255)
        return {
            state: "unreachable",
            detail: err.trim().split("\n").pop() || "ssh could not connect"
        };
    return {
        state: "error",
        detail: "connected, but the phone gave no answer"
    };
}

// ------------------------------------------------------------- formatting

// SI units, the way Android's own Settings counts: 1 GB = 1000 MB.
function bytesText(n) {
    if (!isFinite(n) || n < 0)
        return "?";
    var units = ["B", "kB", "MB", "GB", "TB"];
    var i = 0;
    while (n >= 1000 && i < units.length - 1) {
        n /= 1000;
        i++;
    }
    return (i === 0 ? n.toFixed(0) : (n < 10 ? n.toFixed(2) : (n < 100 ? n.toFixed(1) : n.toFixed(0)))) + " " + units[i];
}

function agoText(ms, nowMs) {
    if (!ms)
        return "";
    var s = Math.max(0, Math.round((nowMs - ms) / 1000));
    if (s < 45)
        return "just now";
    var m = Math.round(s / 60);
    if (m < 60)
        return m + " min ago";
    var h = Math.round(m / 60);
    if (h < 24)
        return h + " h ago";
    return Math.round(h / 24) + " d ago";
}

// "now", "4m", "2h", "3d": the short stamp in front of a notification.
function shortAge(ms, nowMs) {
    if (!ms)
        return "";
    var min = Math.floor((nowMs - ms) / 60000);
    if (min < 1)
        return "now";
    if (min < 60)
        return min + "m";
    var h = Math.floor(min / 60);
    if (h < 24)
        return h + "h";
    return Math.floor(h / 24) + "d";
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function dayText(ms) {
    var d = new Date(ms);
    return d.getDate() + " " + MONTHS[d.getMonth()];
}

function uptimeText(sec) {
    if (!isFinite(sec))
        return "";
    var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
    return d > 0 ? d + "d " + h + "h" : (h > 0 ? h + "h " + m + "m" : m + "m");
}

// Material icon names.
function batteryIcon(b) {
    if (!b || !isFinite(b.level))
        return "battery_unknown";
    if (b.state === "charging" || b.state === "full" && b.plugged !== "")
        return "battery_charging_full";
    var steps = ["battery_0_bar", "battery_1_bar", "battery_2_bar", "battery_3_bar", "battery_4_bar", "battery_5_bar", "battery_6_bar", "battery_full"];
    return steps[Math.max(0, Math.min(7, Math.round(b.level / 100 * 7)))];
}

function signalIcon(c, airplane) {
    if (airplane)
        return "airplanemode_active";
    if (!c || c.noSim)
        return "signal_cellular_nodata";
    if (!c.inService)
        return "signal_cellular_off";
    return ["signal_cellular_0_bar", "signal_cellular_1_bar", "signal_cellular_2_bar", "signal_cellular_3_bar", "signal_cellular_4_bar"][c.level] || "signal_cellular_0_bar";
}

function signalWords(level) {
    return ["no signal", "weak", "fair", "good", "excellent"][level] || "";
}
