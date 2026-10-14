#!/usr/bin/env node
// matrix.js outside the shell:
//
//   node tests/matrix.test.js             synthetic records, then a live
//                                         `matrix log <kind> --json` when
//                                         matrix is installed
//   node tests/matrix.test.js DIR         the same, with saved <kind>.json files
//
// matrix.js and util.js are QML JavaScript resources; without their pragma
// and import lines they are plain JavaScript, run here in sandboxes of their
// own, util.js handed to matrix.js as `Util` the way `.import` would.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { spawnSync } = require("child_process");

function load(file, extra) {
    const src = fs.readFileSync(path.join(__dirname, "..", file), "utf8").replace(/^\.(pragma|import) .*$/gm, "");
    const ctx = Object.assign({}, extra || {});
    vm.createContext(ctx);
    vm.runInContext(src, ctx);
    return ctx;
}

const Util = load("util.js");
const M = load("matrix.js", { Util: Util });

let passed = 0;
function test(name, fn) {
    try {
        fn();
        passed++;
        console.log("ok   " + name);
    } catch (e) {
        console.log("FAIL " + name + "\n     " + e.message);
        process.exitCode = 1;
    }
}

const rec = (o) => JSON.stringify(Object.assign({ host: "nebuchadnezzar", date: null, service: null, command: null, status: "success", name: null, source: null, target: null, total: null, size: null, data: null, log: null, epoch: "1791990000" }, o));
const plain = x => JSON.parse(JSON.stringify(x));

test("records: one per JSON line, noise skipped, time from epoch", () => {
    const r = M.parseRecords(["banner", rec({ epoch: "1791990736" }), "{broken", rec({ epoch: null, date: "2026-10-14T15:14:36Z" }), ""].join("\n"));
    assert.strictEqual(r.length, 2);
    assert.strictEqual(r[0].ms, 1791990736000);
    assert.strictEqual(r[1].ms, Date.parse("2026-10-14T15:14:36Z"));
});

test("unreachable hosts from stderr, colour codes or not", () => {
    assert.deepStrictEqual(plain(M.unreachableHosts("mjolnir is unreachable — its sync records are left out\n\x1b[33mlogos is unreachable — its sync records are left out\x1b[0m\nmjolnir is unreachable — again\n")), ["mjolnir", "logos"]);
    assert.deepStrictEqual(plain(M.unreachableHosts("")), []);
});

test("data pairs: spaces in a value, quoted values", () => {
    assert.deepStrictEqual(plain(M.parseData("ip=10.33.10.143 mac=ee:c2:16:fb:35:4f interface=wlp0s20f3 ssid=LOBA COFFEE SPOTWIFI")), { ip: "10.33.10.143", mac: "ee:c2:16:fb:35:4f", interface: "wlp0s20f3", ssid: "LOBA COFFEE SPOTWIFI" });
    assert.deepStrictEqual(plain(M.parseData('via=shim caller=save.sh pid=810787 unit="tmux-server.service" exit=0')).unit, "tmux-server.service");
    assert.deepStrictEqual(plain(M.parseData(null)), {});
});

test("login lines said the short way", () => {
    assert.strictEqual(M.loginSummary("Accepted publickey for neo from 100.70.50.1 port 50962 ssh2: RSA SHA256:x"), "neo · ssh publickey from 100.70.50.1");
    assert.strictEqual(M.loginSummary("Failed password for invalid user admin from 1.2.3.4 port 22 ssh2"), "failed ssh password for admin from 1.2.3.4");
    assert.strictEqual(M.loginSummary("New session '10' of user 'neo' with class 'user' and type 'tty'."), "neo · new session 10");
    assert.strictEqual(M.loginSummary("pam_unix(sudo:session): session opened for user root(uid=0) by roland(uid=1001)"), "root · session opened by roland");
    assert.strictEqual(M.loginSummary("error: kex_exchange_identification: read: Connection reset by peer [preauth]"), "ssh connection dropped before login");
    assert.strictEqual(M.loginSummary("something else entirely"), "");
});

test("boot: clean or not, how long it ran, one row per boot", () => {
    const text = [
        rec({ host: "mjolnir", status: "fail", data: "boot_id=4ca3 started=2026-10-06T15:54:25+00:00 ended=2026-10-07T08:52:59+00:00", epoch: "1791467444" }),
        rec({ host: "mjolnir", status: "fail", data: "boot_id=4ca3 started=2026-10-06T15:54:25+00:00 ended=2026-10-07T08:52:59+00:00", epoch: "1791367485" }),
        rec({ host: "nebuchadnezzar", status: "success", data: "boot_id=95e8 started=2026-10-11T20:02:25+00:00 ended=2026-10-11T20:33:59+00:00" })
    ].join("\n");
    const rows = M.group("boot", M.parseRecords(text));
    assert.strictEqual(rows.length, 2, "the boot logged twice is one row");
    assert.strictEqual(rows[0].primary, "Unclean shutdown · ran 16h 58m");
    assert.strictEqual(rows[0].count, 2);
    assert.strictEqual(rows[0].ms, Date.parse("2026-10-07T08:52:59+00:00"));
    assert.strictEqual(rows[1].primary, "Clean shutdown · ran 31m");
    assert.deepStrictEqual(plain(M.verdict("boot", M.parseRecords(text), rows)), { text: "1 unclean", tone: "error" });
});

test("system errors: the same message again is one row with a count", () => {
    const text = [1, 2, 3].map(i => rec({ service: "systemd", command: "snapserver", status: "fail", log: "(StreamSessionTCP) Error in socket shutdown", epoch: String(1791990000 - i) })).concat([rec({ host: "mjolnir", service: "systemd", command: "docker", status: "fail", log: "boom" })]).join("\n");
    const recs = M.parseRecords(text);
    const rows = M.group("system", recs);
    assert.deepStrictEqual(plain(rows.map(r => [r.host, r.primary, r.count])), [["nebuchadnezzar", "snapserver", 3], ["mjolnir", "docker", 1]]);
    assert.deepStrictEqual(plain(M.verdict("system", recs, rows)), { text: "4 errors", tone: "error" });
    assert.deepStrictEqual(plain(M.verdict("system", [], [])), { text: "clean", tone: "success" });
    assert.strictEqual(M.verdict("system", recs, rows, true).text, "4+ errors", "the limit was reached: at least");
});

test("sync: syncthing folded per folder, a skipped backup says why", () => {
    const text = [
        rec({ host: "mjolnir", service: "sync-backup-manager", command: "rsync", status: "warn", name: "mjolnir-rom-to-logos", source: "/a", target: "logos:/b", log: "Skipped: logos battery is at 6%, below the required 20%." }),
        rec({ host: "mjolnir", service: "syncthing", command: "sync", name: "claude", source: "projects/x.jsonl" }),
        rec({ host: "mjolnir", service: "syncthing", command: "sync", name: "claude", source: "projects/y.jsonl" }),
        rec({ host: "mjolnir", service: "sync-backup-manager", command: "borg", status: "started", name: "appdata", source: "/src", target: "/dst::x" })
    ].join("\n");
    const recs = M.parseRecords(text);
    const rows = M.group("sync", recs);
    assert.deepStrictEqual(plain(rows.map(r => [r.primary, r.secondary, r.count])), [
        ["mjolnir-rom-to-logos · rsync warning", "Skipped: logos battery is at 6%, below the required 20%.", 1],
        ["claude · synced", "last: projects/x.jsonl", 2],
        ["appdata · borg started", "/src → /dst::x", 1]
    ]);
    assert.deepStrictEqual(plain(M.verdict("sync", recs, rows)), { text: "1 warning", tone: "warning" });
});

test("file: what was done, how many, and by whom", () => {
    const r = M.parseRecords(rec({ service: "fct", command: "rm", name: "pane-A:1.1", source: "/home/neo/.config/tmux/x/pane-A:1.1", total: "34", log: "Run by save.sh in tmux-server.service. Command: rm /a /b" }));
    const rows = M.group("file", r.concat(r));
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(rows[0].primary, "rm pane-A:1.1 +33 more");
    assert.strictEqual(rows[0].secondary, "Run by save.sh in tmux-server.service");
    assert.strictEqual(rows[0].count, 2);
});

test("network devices: one row per device, however many scans saw it", () => {
    const d = "ip=10.33.10.1 mac=02:93:64:1f:78:f8 interface=wlp0s20f3 ssid=LOBA COFFEE SPOTWIFI";
    const recs = M.parseRecords([rec({ data: d }), rec({ data: d }), rec({ host: "mjolnir", data: "ip=192.168.0.1 mac=00:50:f1:80:00:00 interface=enp3s0 ssid=unknown" })].join("\n"));
    const rows = M.group("network-device", recs);
    assert.deepStrictEqual(plain(rows.map(r => [r.primary, r.secondary, r.count])), [["10.33.10.1  02:93:64:1f:78:f8", "LOBA COFFEE SPOTWIFI · wlp0s20f3", 2], ["192.168.0.1  00:50:f1:80:00:00", "enp3s0", 1]]);
    assert.strictEqual(M.verdict("network-device", recs, rows).text, "2 devices");
});

test("build and logger rows", () => {
    const b = M.group("build", M.parseRecords(rec({ host: "mjolnir", service: "smith", command: "build", data: "generation=205 version=26.05.20260924.c508844" })));
    assert.strictEqual(b[0].primary, "Generation 205");
    assert.strictEqual(b[0].secondary, "NixOS 26.05.20260924.c508844 · by smith");
    const l = M.group("logger", M.parseRecords([rec({ service: "logger", command: "journalctl", status: "started", name: "boot", target: "/x/boot.json" }), rec({ service: "logger", command: "journalctl", status: "fail", log: "a follower exited unexpectedly; restarting" })].join("\n")));
    assert.deepStrictEqual(plain(l.map(r => r.primary)), ["boot · started", "logger · failed"]);
});

test("group: a limit keeps the newest rows but still counts repeats", () => {
    const recs = M.parseRecords(["a", "b", "a", "c", "a"].map(x => rec({ command: x, status: "fail", log: x })).join("\n"));
    const rows = M.group("system", recs, 2);
    assert.deepStrictEqual(plain(rows.map(r => [r.primary, r.count])), [["a", 3], ["b", 1]]);
    assert.deepStrictEqual(plain(M.hostsOf(M.parseRecords([rec({ host: "x" }), rec({ host: "y" }), rec({ host: "x" })].join("\n")))), ["x", "y"]);
});

// ----------------------------------------------------------------- real data

const savedDir = process.argv[2];
const haveMatrix = spawnSync("sh", ["-c", "command -v matrix"]).status === 0;

for (const k of M.KINDS) {
    if (!savedDir && !haveMatrix)
        break;
    test("real " + k.kind + (savedDir ? " (saved)" : " (live)"), () => {
        let text;
        let stderr = "";
        if (savedDir) {
            text = fs.readFileSync(path.join(savedDir, k.kind + ".json"), "utf8");
        } else {
            const r = spawnSync("matrix", ["log", k.kind, "--json", "--limit", "200"], { encoding: "utf8", timeout: 120000, maxBuffer: 64 << 20 });
            text = r.stdout;
            stderr = r.stderr;
        }
        const lines = text.split("\n").filter(l => l.trim().length > 0);
        const recs = M.parseRecords(text);
        assert.strictEqual(recs.length, lines.length, "every line is a record");
        for (let i = 1; i < recs.length; i++)
            assert.ok(recs[i].ms > 0, "a time on record " + i);
        const rows = M.group(k.kind, recs, 80);
        assert.ok(rows.length > 0 || recs.length === 0);
        for (const r of rows)
            assert.ok(r.primary.length > 0, "a first line on every row: " + JSON.stringify(r));
        const v = M.verdict(k.kind, recs, rows);
        const gone = M.unreachableHosts(stderr);
        console.log("     " + recs.length + " records → " + rows.length + " rows · " + M.hostsOf(recs).join(", ") + (gone.length ? " · unreachable: " + gone.join(", ") : "") + " · " + v.text + " · e.g. " + (rows[0] ? rows[0].primary + " | " + rows[0].secondary.slice(0, 60) : "—"));
    });
}

console.log("\n" + passed + " passed" + (process.exitCode ? ", some FAILED" : ""));
