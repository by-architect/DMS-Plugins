#!/usr/bin/env node
// speedtest.js outside quickshell:
//
//   node tests/speedtest.test.js           what each program prints, read back
//   node tests/speedtest.test.js --live    plus one real test through
//                                          scripts/run.sh (uses the network)
//
// speedtest.js is a QML ".pragma library" file; with the pragma line removed
// it is plain JavaScript, run here in a sandbox of its own.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { spawnSync } = require("child_process");

const src = fs.readFileSync(path.join(__dirname, "..", "speedtest.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const S = {};
vm.createContext(S);
vm.runInContext(src, S);

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

const near = (a, b, eps) => assert.ok(Math.abs(a - b) < (eps || 1e-6), a + " vs " + b);

// speedtest-cli 2.1.3 --json
const SIVEL = JSON.stringify({
    download: 93812345.6, upload: 12345678.9, ping: 15.123,
    server: { url: "http://speedtest.example:8080/speedtest/upload.php", lat: "41.0", lon: "29.0", name: "Istanbul", country: "Turkey", cc: "TR", sponsor: "Turk Telekom", id: "12345", host: "speedtest.example:8080", d: 12.34, latency: 15.123 },
    timestamp: "2026-10-14T15:20:01.123456Z", bytes_sent: 12345678, bytes_received: 98765432, share: null,
    client: { ip: "203.0.113.7", lat: "41.0", lon: "29.0", isp: "Turk Telekom", isprating: "3.7", rating: "0", ispdlavg: "0", ispulavg: "0", loggedin: "0", country: "TR" }
});

// Ookla speedtest -f json, with a log record before the result
const OOKLA = [
    JSON.stringify({ type: "log", timestamp: "2026-10-14T15:20:00Z", message: "Error: [0] Timeout occurred in connect.", level: "warning" }),
    JSON.stringify({
        type: "result", timestamp: "2026-10-14T15:20:01Z",
        ping: { jitter: 0.52, latency: 10.25, low: 9.8, high: 11.0 },
        download: { bandwidth: 11726250, bytes: 120000000, elapsed: 10000 },
        upload: { bandwidth: 2500000, bytes: 25000000, elapsed: 10000 },
        packetLoss: 0.4, isp: "Superonline",
        interface: { internalIp: "10.0.0.2", name: "wlp0s20f3", macAddr: "AA:BB:CC:DD:EE:FF", isVpn: false, externalIp: "198.51.100.9" },
        server: { id: 4321, host: "speedtest.example", port: 8080, name: "Turkcell", location: "Ankara", country: "Turkey", ip: "192.0.2.1" },
        result: { id: "uuid", url: "https://www.speedtest.net/result/c/uuid", persisted: true }
    })
].join("\n");

// librespeed-cli --json
const LIBRE = JSON.stringify([{ timestamp: "2026-10-14T15:20:01Z", server: { name: "Frankfurt, Germany (Clouvider)", url: "https://fra.speedtest.clouvider.net/backend" }, client: { ip: "203.0.113.7", org: "AS9121 Turk Telekom" }, bytes_sent: 1, bytes_received: 1, ping: 48.2, jitter: 3.1, upload: 11.52, download: 87.4, share: "" }]);

test("speedtest-cli: bit/s to Mbit/s, server and client", () => {
    const r = S.parseResult(SIVEL);
    near(r.down, 93.8123456);
    near(r.up, 12.3456789);
    near(r.ping, 15.123);
    assert.strictEqual(r.jitter, -1);
    assert.strictEqual(r.server, "Turk Telekom");
    assert.strictEqual(r.location, "Istanbul, Turkey (12 km)");
    assert.strictEqual(r.isp, "Turk Telekom");
    assert.strictEqual(r.ip, "203.0.113.7");
    assert.strictEqual(r.tool, "speedtest-cli");
});

test("speedtest-cli through nearest.py says so", () => {
    const r = S.parseResult(JSON.stringify(Object.assign(JSON.parse(SIVEL), { picked: "nearest" })));
    assert.strictEqual(r.tool, "speedtest-cli, nearest server");
    near(r.down, 93.8123456);
});

test("Ookla: bytes/s to Mbit/s, the log line before it skipped", () => {
    const r = S.parseResult(OOKLA);
    near(r.down, 93.81);
    near(r.up, 20);
    near(r.ping, 10.25);
    near(r.jitter, 0.52);
    near(r.loss, 0.4);
    assert.strictEqual(r.server, "Turkcell");
    assert.strictEqual(r.location, "Ankara, Turkey");
    assert.strictEqual(r.ip, "198.51.100.9");
    assert.strictEqual(r.url, "https://www.speedtest.net/result/c/uuid");
    assert.strictEqual(r.tool, "Ookla speedtest");
});

test("librespeed: already Mbit/s", () => {
    const r = S.parseResult(LIBRE);
    near(r.down, 87.4);
    near(r.up, 11.52);
    near(r.jitter, 3.1);
    assert.strictEqual(r.isp, "AS9121 Turk Telekom");
    assert.strictEqual(r.tool, "librespeed-cli");
});

test("nothing that is a result: null", () => {
    assert.strictEqual(S.parseResult(""), null);
    assert.strictEqual(S.parseResult("Retrieving speedtest.net configuration...\n"), null);
    assert.strictEqual(S.parseResult('{"type":"log","message":"x"}'), null);
    assert.strictEqual(S.parseResult("[]"), null);
});

test("error lines: the program's ERROR, else its last word", () => {
    assert.strictEqual(S.errorLine("Retrieving speedtest.net configuration...\nCannot retrieve speedtest configuration\nERROR: HTTP Error 403: Forbidden\n", 1), "HTTP Error 403: Forbidden");
    assert.strictEqual(S.errorLine("[error] Error: [11] Cannot read: Resource temporarily unavailable\n", 2), "Error: [11] Cannot read: Resource temporarily unavailable");
    assert.strictEqual(S.errorLine("No speed test program found: install speedtest-cli\n", 127), "No speed test program found: install speedtest-cli");
    assert.strictEqual(S.errorLine("", -1), "the test did not finish in time");
    assert.strictEqual(S.errorLine("", 1), "the speed test exited with code 1");
    assert.strictEqual(S.errorLine("", 0), "the speed test printed no result");
});

test("schedule: interval after a test, retry sooner after a failure, never before ready", () => {
    const H = 3600000;
    assert.strictEqual(S.nextDue(0, 5, false, 10, 0), 0, "0 minutes: never");
    assert.strictEqual(S.nextDue(60, 1000, false, 10, 0), 1000 + H);
    assert.strictEqual(S.nextDue(60, 1000, true, 10, 0), 1000 + 600000);
    assert.strictEqual(S.nextDue(5, 1000, true, 10, 0), 1000 + 300000, "a retry is never later than the interval");
    assert.strictEqual(S.nextDue(60, 0, false, 10, 777), 777, "never tested: as soon as ready");
    assert.strictEqual(S.nextDue(60, 1000, false, 10, 5 * H), 5 * H, "due long ago: not before ready");
});

test("text", () => {
    assert.deepStrictEqual([-1, 0, 4.44, 9.96, 10, 94.4, 999.4, 1234, 12345].map(S.shortMbps), ["--", "0.0", "4.4", "10.0", "10", "94", "999", "1.2G", "12G"]);
    assert.strictEqual(S.mbpsText(93.81), "93.8 Mbit/s");
    assert.strictEqual(S.mbpsText(512.3), "512 Mbit/s");
    assert.strictEqual(S.mbpsText(1234), "1.23 Gbit/s");
    assert.strictEqual(S.msText(15.123), "15.1 ms");
    const r = { down: 93.8, up: 12.3, ping: 15.1 };
    assert.strictEqual(S.pillText(r, "both"), "↓94 ↑12");
    assert.strictEqual(S.pillText(r, "down"), "↓94");
    assert.strictEqual(S.pillText(r, "all"), "↓94 ↑12 15ms");
    assert.strictEqual(S.pillText(null, "both"), "--");
    assert.strictEqual(S.agoText(0, 1), "never");
    assert.strictEqual(S.agoText(1000, 1000 + 125000), "2 min ago");
    assert.strictEqual(S.inText(1000 + 90 * 60000, 1000), "in 1 h 30 min");
    assert.strictEqual(S.inText(1000 + 30000, 1000), "in under a minute");
});

test("run.sh: a program nobody has is exit 127 with a sentence", () => {
    const r = spawnSync("/bin/sh", [path.join(__dirname, "..", "scripts", "run.sh"), "librespeed"], { encoding: "utf8", env: { PATH: "/nonexistent" } });
    assert.strictEqual(r.status, 127);
    assert.ok(/not installed/.test(r.stderr), r.stderr);
    const all = spawnSync("/bin/sh", [path.join(__dirname, "..", "scripts", "run.sh")], { encoding: "utf8", env: { PATH: "/nonexistent" } });
    assert.strictEqual(all.status, 127);
    assert.strictEqual(S.errorLine(all.stderr, all.status), "No speed test program found: install speedtest-cli, Ookla's speedtest or librespeed-cli");
});

test("nearest.py: exit 3 without speedtest-cli's module, so run.sh falls back", () => {
    const r = spawnSync("python3", [path.join(__dirname, "..", "scripts", "nearest.py")], { encoding: "utf8", env: { PATH: process.env.PATH, PYTHONPATH: "/nonexistent", PYTHONNOUSERSITE: "1" } });
    if (r.error)
        return; // no python3 here: run.sh never calls nearest.py either
    // A system-wide speedtest module would make this 0 or 1 instead; only
    // "not importable" must be 3.
    let importable = spawnSync("python3", ["-c", "import speedtest"], { env: { PATH: process.env.PATH, PYTHONNOUSERSITE: "1" } }).status === 0;
    if (!importable)
        assert.strictEqual(r.status, 3, r.stderr);
});

test("run.sh finds speedtest-cli's module next to the program", () => {
    const sh = 'has() { command -v "$1" >/dev/null 2>&1; }\n' + fs.readFileSync(path.join(__dirname, "..", "scripts", "run.sh"), "utf8").match(/^sivel_path\(\) \{[\s\S]*?^\}/m)[0] + "\nsivel_path\n";
    const r = spawnSync("/bin/sh", ["-c", sh], { encoding: "utf8" });
    const found = r.stdout.trim();
    const have = spawnSync("/bin/sh", ["-c", "command -v speedtest-cli || command -v speedtest"]).status === 0;
    if (have && found)
        assert.ok(fs.existsSync(path.join(found, "speedtest.py")), found);
    console.log("     " + (found || "(not next to the program: pip installs need no path)"));
});

if (process.argv.includes("--live")) {
    test("live: one real test through run.sh", () => {
        const t0 = Date.now();
        const r = spawnSync("sh", [path.join(__dirname, "..", "scripts", "run.sh")], { encoding: "utf8", timeout: 180000 });
        const res = S.parseResult(r.stdout);
        assert.ok(res, "a result: " + S.errorLine(r.stderr, r.status));
        assert.ok(res.down > 0 && res.up > 0 && res.ping > 0, JSON.stringify(res));
        console.log("     " + S.mbpsText(res.down) + " down, " + S.mbpsText(res.up) + " up, " + S.msText(res.ping) + " via " + res.tool + " in " + Math.round((Date.now() - t0) / 1000) + " s (" + res.server + ")");
    });
}

console.log("\n" + passed + " passed" + (process.exitCode ? ", some FAILED" : ""));
