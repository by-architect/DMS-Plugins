import QtQuick
import Quickshell.Io
import "util.js" as Util

// Central data layer for the system panel. Every tile reads from here so the
// panel runs one set of processes per refresh instead of one per tile.
Item {
    id: root

    property int journalDays: 30
    readonly property string since: "-" + journalDays + " days"

    readonly property bool busy: lastLogins.busy || sshAuth.busy || boots.busy || cleanShutdowns.busy || tailscale.busy || sessions.busy || establishedSsh.busy || sudoEvents.busy || failedUnits.busy || systemState.busy || listeningPorts.busy || overview.busy

    signal refreshed

    function refreshAll() {
        lastLogins.refresh();
        sshAuth.refresh();
        boots.refresh();
        cleanShutdowns.refresh();
        tailscale.refresh();
        sessions.refresh();
        establishedSsh.refresh();
        sudoEvents.refresh();
        failedUnits.refresh();
        systemState.refresh();
        listeningPorts.refresh();
        overview.refresh();
        refreshed();
    }

    // ---------------------------------------------------------------- logins

    // Successful logins of every kind come from wtmp; failed attempts come from
    // the journal, because /var/log/btmp (lastb) is root-only.
    Collector {
        id: lastLogins

        command: ["last", "-w", "-n", "120", "--time-format", "iso"]
        parse: text => {
            const out = [];
            const lines = text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                const line = lines[i];
                if (!line.trim() || line.indexOf("wtmp begins") === 0)
                    continue;

                const parts = line.split(/\s{2,}/).map(s => s.trim()).filter(s => s.length > 0);
                if (parts.length < 3)
                    continue;

                const user = parts[0];
                if (user === "reboot" || user === "shutdown" || user === "runlevel")
                    continue;

                var timeIdx = -1;
                for (var j = 1; j < parts.length; j++) {
                    if (/^\d{4}-\d{2}-\d{2}T/.test(parts[j])) {
                        timeIdx = j;
                        break;
                    }
                }
                if (timeIdx < 0)
                    continue;

                const tty = parts[1] || "";
                const host = timeIdx >= 3 ? parts[2] : "";
                const timeField = parts[timeIdx];
                const trailer = parts[timeIdx + 1] || "";

                const startIso = timeField.split(" - ")[0].trim();
                const ts = Util.parseIso(startIso);
                if (!ts)
                    continue;

                var method = "local";
                if (host)
                    method = "ssh";
                else if (tty.indexOf("tty") === 0)
                    method = "tty";
                else if (tty.indexOf("pts") === 0)
                    method = "pts";

                out.push({
                    ts: ts,
                    user: user,
                    result: "success",
                    method: method,
                    host: host,
                    tty: tty,
                    detail: trailer.indexOf("still") === 0 ? "still logged in" : trailer.replace(/[()]/g, ""),
                    active: trailer.indexOf("still") === 0
                });
            }
            return out;
        }
    }

    Collector {
        id: sshAuth

        command: ["journalctl", "-t", "sshd", "-t", "sshd-session", "-o", "json", "--no-pager", "--since", root.since, "--output-fields=MESSAGE,__REALTIME_TIMESTAMP"]
        parse: text => {
            const out = [];
            const entries = Util.parseNdjson(text);
            for (var i = 0; i < entries.length; i++) {
                const msg = Util.journalMessage(entries[i]);
                const ts = Util.journalMs(entries[i]);
                if (!msg || !ts)
                    continue;

                var m;
                if ((m = msg.match(/^Failed (\S+) for (?:invalid user )?(\S+) from (\S+) port/))) {
                    out.push({
                        ts: ts,
                        user: m[2],
                        result: "failed",
                        method: "ssh",
                        host: m[3],
                        tty: "",
                        detail: "bad " + m[1],
                        active: false
                    });
                } else if ((m = msg.match(/^Invalid user (\S+) from (\S+) port/))) {
                    out.push({
                        ts: ts,
                        user: m[1] || "(none)",
                        result: "failed",
                        method: "ssh",
                        host: m[2],
                        tty: "",
                        detail: "invalid user",
                        active: false
                    });
                } else if ((m = msg.match(/^error: maximum authentication attempts exceeded for (?:invalid user )?(\S+) from (\S+) port/))) {
                    out.push({
                        ts: ts,
                        user: m[1],
                        result: "failed",
                        method: "ssh",
                        host: m[2],
                        tty: "",
                        detail: "too many attempts",
                        active: false
                    });
                }
            }
            return out;
        }
    }

    readonly property var loginEvents: {
        const success = lastLogins.result || [];
        const failed = sshAuth.result || [];
        const merged = success.concat(failed);
        merged.sort((a, b) => b.ts - a.ts);
        return merged.slice(0, 200);
    }

    readonly property int failedLoginCount: {
        const list = sshAuth.result || [];
        return list.length;
    }

    // ----------------------------------------------------------------- boots

    Collector {
        id: boots

        command: ["journalctl", "--list-boots", "-o", "json", "--no-pager"]
        parse: text => {
            var list = [];
            try {
                list = JSON.parse(text);
            } catch (e) {
                list = Util.parseNdjson(text);
            }
            if (!Array.isArray(list))
                return [];
            return list.map(b => ({
                        index: b.index,
                        bootId: b.boot_id,
                        first: Math.floor(b.first_entry / 1000),
                        last: Math.floor(b.last_entry / 1000),
                        seconds: Math.floor((b.last_entry - b.first_entry) / 1000000)
                    }));
        }
    }

    // Every boot id that logged a graceful systemd-shutdown. Any older boot
    // missing from this set went down uncleanly (power loss, panic, hard reset).
    Collector {
        id: cleanShutdowns

        command: ["journalctl", "-t", "systemd-shutdown", "-o", "json", "--no-pager", "--output-fields=_BOOT_ID"]
        parse: text => {
            const ids = {};
            const entries = Util.parseNdjson(text);
            for (var i = 0; i < entries.length; i++) {
                const id = entries[i]._BOOT_ID;
                if (id)
                    ids[id] = true;
            }
            return ids;
        }
    }

    property var bootErrors: ({})
    property var _bootErrorQueue: []
    property string _bootErrorCurrent: ""

    readonly property var bootList: {
        const list = boots.result || [];
        const clean = cleanShutdowns.result || {};
        const recent = list.slice(-14).reverse();
        return recent.map(b => {
            var status = "clean";
            if (b.index === 0)
                status = "running";
            else if (!clean[b.bootId])
                status = "unclean";
            return {
                index: b.index,
                bootId: b.bootId,
                first: b.first,
                last: b.last,
                seconds: b.seconds,
                status: status,
                errors: root.bootErrors[b.bootId] || null
            };
        });
    }

    readonly property int uncleanBootCount: bootList.filter(b => b.status === "unclean").length

    // Error context is only fetched for boots that actually ended badly, one at
    // a time, so a long boot history does not fan out into dozens of processes.
    function _queueBootErrors() {
        const targets = bootList.filter(b => b.status === "unclean" && !bootErrors[b.bootId]).slice(0, 5).map(b => b.bootId);
        if (!targets.length)
            return;
        _bootErrorQueue = targets;
        _drainBootErrors();
    }

    function _drainBootErrors() {
        if (_bootErrorCurrent || !_bootErrorQueue.length)
            return;
        const next = _bootErrorQueue.shift();
        _bootErrorCurrent = next;
        bootErrorProc.command = ["journalctl", "-b", next, "-p", "3", "-n", "6", "--no-pager", "-o", "cat"];
        bootErrorProc.running = true;
    }

    Process {
        id: bootErrorProc

        running: false

        stdout: StdioCollector {
            id: bootErrorOut
        }

        onExited: {
            const id = root._bootErrorCurrent;
            if (id) {
                const lines = (bootErrorOut.text || "").split("\n").map(l => l.trim()).filter(l => l.length > 0);
                const next = Object.assign({}, root.bootErrors);
                next[id] = lines.length ? lines : ["no error-level messages recorded"];
                root.bootErrors = next;
            }
            root._bootErrorCurrent = "";
            root._drainBootErrors();
        }
    }

    onBootListChanged: Qt.callLater(_queueBootErrors)

    // ------------------------------------------------------------- tailscale

    Collector {
        id: tailscale

        command: ["tailscale", "status", "--json"]
        parse: text => {
            const data = JSON.parse(text);
            const devices = [];

            function toDevice(node, isSelf) {
                if (!node)
                    return null;
                const ips = node.TailscaleIPs || [];
                return {
                    name: node.HostName || (node.DNSName || "").split(".")[0] || "unknown",
                    dnsName: (node.DNSName || "").replace(/\.$/, ""),
                    ip: ips.length ? ips[0] : "",
                    ip6: ips.length > 1 ? ips[1] : "",
                    online: isSelf ? true : (node.Online === true),
                    os: node.OS || "",
                    isSelf: isSelf,
                    exitNode: node.ExitNode === true,
                    exitNodeOption: node.ExitNodeOption === true,
                    active: node.Active === true,
                    lastSeen: node.LastSeen ? Util.parseIso(node.LastSeen) : 0,
                    rx: node.RxBytes || 0,
                    tx: node.TxBytes || 0,
                    relay: node.Relay || "",
                    curAddr: node.CurAddr || ""
                };
            }

            const self = toDevice(data.Self, true);
            if (self)
                devices.push(self);

            const peers = data.Peer || {};
            for (const key in peers) {
                const d = toDevice(peers[key], false);
                if (d)
                    devices.push(d);
            }

            devices.sort((a, b) => {
                if (a.isSelf !== b.isSelf)
                    return a.isSelf ? -1 : 1;
                if (a.online !== b.online)
                    return a.online ? -1 : 1;
                return a.name.localeCompare(b.name);
            });

            return {
                backendState: data.BackendState || "",
                version: data.Version || "",
                tailnet: data.MagicDNSSuffix || "",
                selfIps: (data.TailscaleIPs || []),
                devices: devices
            };
        }
    }

    readonly property var tailscaleDevices: (tailscale.result && tailscale.result.devices) || []
    readonly property bool tailscalePresent: !tailscale.error && !!tailscale.result

    // -------------------------------------------------------------- sessions

    Collector {
        id: sessions

        command: ["sh", "-c", "ids=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); [ -n \"$ids\" ] || exit 0; loginctl show-session $ids -p Id -p Name -p User -p Remote -p RemoteHost -p Service -p Type -p Class -p State -p TTY -p Seat -p Timestamp -p Leader -p Active 2>/dev/null"]
        parse: text => {
            const blocks = Util.parseKeyValueBlocks(text);
            return blocks.map(b => ({
                        id: b.Id || "",
                        user: b.Name || "",
                        uid: b.User || "",
                        remote: b.Remote === "yes",
                        remoteHost: b.RemoteHost || "",
                        service: b.Service || "",
                        type: b.Type || "",
                        sessionClass: b.Class || "",
                        state: b.State || "",
                        tty: b.TTY || "",
                        seat: b.Seat || "",
                        leader: b.Leader || "",
                        active: b.Active === "yes",
                        ts: Util.parseSystemdTimestamp(b.Timestamp || "")
                    })).sort((a, b) => b.ts - a.ts);
        }
    }

    readonly property var allSessions: sessions.result || []
    readonly property var remoteSessions: allSessions.filter(s => s.remote)
    readonly property var localSessions: allSessions.filter(s => !s.remote)

    // Established inbound connections on port 22 that may not have reached a
    // login session yet (mid-handshake, or a session systemd-logind did not track).
    Collector {
        id: establishedSsh

        command: ["sh", "-c", "ss -tnH state established '( sport = :22 )' 2>/dev/null"]
        parse: text => {
            const out = [];
            const lines = text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                const parts = lines[i].trim().split(/\s+/).filter(p => p.length > 0);
                if (parts.length < 4)
                    continue;
                const local = parts[2];
                const peer = parts[3];
                const cut = peer.lastIndexOf(":");
                out.push({
                    localAddr: local,
                    peer: cut > 0 ? peer.substring(0, cut) : peer,
                    peerPort: cut > 0 ? peer.substring(cut + 1) : ""
                });
            }
            return out;
        }
    }

    readonly property var inboundSsh: establishedSsh.result || []

    // ------------------------------------------------------------------ sudo

    Collector {
        id: sudoEvents

        command: ["journalctl", "-t", "sudo", "-o", "json", "--no-pager", "--since", root.since, "--output-fields=MESSAGE,__REALTIME_TIMESTAMP"]
        parse: text => {
            const out = [];
            const entries = Util.parseNdjson(text);
            for (var i = 0; i < entries.length; i++) {
                const msg = Util.journalMessage(entries[i]);
                const ts = Util.journalMs(entries[i]);
                if (!msg || !ts)
                    continue;

                var m;
                if ((m = msg.match(/^\s*(\S+)\s*:\s*(?:\S.*?;\s*)?TTY=(\S*)\s*;\s*PWD=(\S*)\s*;\s*USER=(\S+)\s*;\s*COMMAND=(.+)$/))) {
                    const failure = msg.match(/authentication failure|NOT in the sudoers|command not allowed|incorrect password/i);
                    out.push({
                        ts: ts,
                        user: m[1],
                        tty: m[2],
                        pwd: m[3],
                        asUser: m[4],
                        command: m[5],
                        result: failure ? "failed" : "success"
                    });
                } else if ((m = msg.match(/^\s*(\S+)\s*:\s*(\d+ incorrect password attempts?|user NOT in the sudoers file.*|authentication failure.*)/i))) {
                    out.push({
                        ts: ts,
                        user: m[1],
                        tty: "",
                        pwd: "",
                        asUser: "",
                        command: m[2],
                        result: "failed"
                    });
                }
            }
            out.sort((a, b) => b.ts - a.ts);
            return out.slice(0, 120);
        }
    }

    readonly property var sudoList: sudoEvents.result || []

    // ----------------------------------------------------------------- units

    Collector {
        id: failedUnits

        command: ["systemctl", "list-units", "--failed", "--all", "--output=json", "--no-pager"]
        parse: text => {
            const trimmed = (text || "").trim();
            if (!trimmed)
                return [];
            const list = JSON.parse(trimmed);
            if (!Array.isArray(list))
                return [];
            return list.map(u => ({
                        unit: u.unit || "",
                        load: u.load || "",
                        active: u.active || "",
                        sub: u.sub || "",
                        description: u.description || ""
                    }));
        }
    }

    Collector {
        id: systemState

        command: ["sh", "-c", "systemctl is-system-running 2>/dev/null || true"]
        parse: text => (text || "").trim()
    }

    readonly property var failedUnitList: failedUnits.result || []
    readonly property string systemdState: systemState.result || ""

    // ----------------------------------------------------------------- ports

    Collector {
        id: listeningPorts

        command: ["sh", "-c", "ss -tulnHp 2>/dev/null"]
        parse: text => {
            const out = [];
            const lines = text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                const line = lines[i].trim();
                if (!line)
                    continue;
                const parts = line.split(/\s+/).filter(p => p.length > 0);
                if (parts.length < 5)
                    continue;

                const proto = parts[0];
                const local = parts[4];
                const cut = local.lastIndexOf(":");
                const addr = cut > 0 ? local.substring(0, cut) : local;
                const port = cut > 0 ? local.substring(cut + 1) : "";

                var procName = "";
                const procField = parts.slice(6).join(" ");
                const pm = procField.match(/users:\(\("([^"]+)"/);
                if (pm)
                    procName = pm[1];

                const exposed = addr === "0.0.0.0" || addr === "*" || addr === "[::]" || addr === "::";

                out.push({
                    proto: proto,
                    addr: addr,
                    port: port,
                    portNum: parseInt(port, 10) || 0,
                    process: procName,
                    exposed: exposed
                });
            }
            out.sort((a, b) => {
                if (a.exposed !== b.exposed)
                    return a.exposed ? -1 : 1;
                return a.portNum - b.portNum;
            });
            return out;
        }
    }

    readonly property var portList: listeningPorts.result || []
    readonly property int exposedPortCount: portList.filter(p => p.exposed).length

    // -------------------------------------------------------------- overview

    Collector {
        id: overview

        command: ["sh", "-c", "echo \"host=$(hostname 2>/dev/null)\"; echo \"kernel=$(uname -r 2>/dev/null)\"; echo \"arch=$(uname -m 2>/dev/null)\"; echo \"os=$(. /etc/os-release 2>/dev/null; echo $PRETTY_NAME)\"; echo \"uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)\"; echo \"loadavg=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)\"; echo \"boottime=$(systemd-analyze 2>/dev/null | head -1)\"; echo \"firewall=$(systemctl is-active firewall 2>/dev/null || systemctl is-active nftables 2>/dev/null || systemctl is-active iptables 2>/dev/null)\"; echo \"sshd=$(systemctl is-active sshd 2>/dev/null)\""]
        parse: text => {
            const map = {};
            const lines = text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                const eq = lines[i].indexOf("=");
                if (eq <= 0)
                    continue;
                map[lines[i].substring(0, eq)] = lines[i].substring(eq + 1).trim();
            }
            const bootMatch = (map.boottime || "").match(/=\s*([\d.]+m?s(?:\s+[\d.]+m?s)?)\s*$/);
            return {
                host: map.host || "",
                kernel: map.kernel || "",
                arch: map.arch || "",
                os: map.os || "",
                uptimeSeconds: parseFloat(map.uptime || "0"),
                loadavg: map.loadavg || "",
                bootTime: bootMatch ? bootMatch[1] : (map.boottime || ""),
                firewall: map.firewall || "unknown",
                sshd: map.sshd || "unknown"
            };
        }
    }

    readonly property var overviewData: overview.result || null

    // ------------------------------------------------- per-tile load reporting

    readonly property bool lastLoginsRan: lastLogins.ran && sshAuth.ran
    readonly property string loginsError: lastLogins.error && sshAuth.error ? lastLogins.error : ""

    readonly property bool bootsRan: boots.ran && cleanShutdowns.ran
    readonly property string bootsError: boots.error

    readonly property bool tailscaleRan: tailscale.ran
    readonly property string tailscaleError: {
        if (!tailscale.error)
            return "";
        if (tailscale.error.indexOf("no response") !== -1)
            return "tailscale not installed";
        if (tailscale.error.indexOf("failed to connect") !== -1)
            return "tailscaled is not running";
        return tailscale.error;
    }
    readonly property var tailscaleInfo: tailscale.result || null

    readonly property bool sessionsRan: sessions.ran
    readonly property string sessionsError: sessions.error

    readonly property bool sudoRan: sudoEvents.ran
    readonly property string sudoError: sudoEvents.error

    readonly property bool unitsRan: failedUnits.ran && systemState.ran
    readonly property string unitsError: failedUnits.error

    readonly property bool portsRan: listeningPorts.ran
    readonly property string portsError: listeningPorts.error

    readonly property bool overviewRan: overview.ran
    readonly property string overviewError: overview.error
}
