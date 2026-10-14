#!/usr/bin/env node
// The widget's arithmetic and parsing, outside quickshell:
//
//   node tests/procstat.test.js     synthetic cases, then live /proc and ps
//
// procstat.js is a QML ".pragma library" file; with the pragma line removed it
// is plain JavaScript, run here in a sandbox of its own.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { spawnSync } = require("child_process");

const src = fs.readFileSync(path.join(__dirname, "..", "procstat.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
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

const sleepMs = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// An independent, deliberately naive version of the same formula, so the
// real-data checks below are not the code checking itself.
function naiveBusy(a, b) {
    const f = l => l.trim().split(/\s+/).slice(1, 9).map(Number);
    const x = f(a), y = f(b);
    const d = y.map((v, i) => v - x[i]);
    const total = d.reduce((s, v) => s + v, 0);
    return (total - d[3] - d[4]) / total * 100;
}

// -------------------------------------------------------------- synthetic

test("busy share: user+system over everything, iowait counts as idle", () => {
    const a = S.parseStat("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 100 0 100 700 100 0 0 0 0 0\n");
    const b = S.parseStat("cpu  200 0 150 1300 150 0 0 0 0 0\ncpu0 200 0 150 1300 150 0 0 0 0 0\n");
    // delta: user 100, system 50, idle 600, iowait 50 -> 150 busy of 800
    const m = S.measure(a, b);
    assert.strictEqual(m.total, 18.75);
    assert.strictEqual(m.cores[0].usage, 18.75);
});

test("guest time is not counted twice", () => {
    const a = S.parseStat("cpu  0 0 0 0 0 0 0 0 0 0\n");
    const b = S.parseStat("cpu  50 0 0 50 0 0 0 0 50 0\n"); // guest 50 is inside user's 50
    assert.strictEqual(S.measure(a, b).total, 50);
});

test("steal counts as busy, irq and softirq too", () => {
    const a = S.parseStat("cpu  0 0 0 0 0 0 0 0 0 0\n");
    const b = S.parseStat("cpu  0 0 0 70 0 10 10 10 0 0\n");
    assert.strictEqual(S.measure(a, b).total, 30);
});

test("first reading has no number, and neither does a new core", () => {
    const a = S.parseStat("cpu  1 1 1 1 1 1 1 1 0 0\ncpu0 1 1 1 1 1 1 1 1 0 0\n");
    const b = S.parseStat("cpu  9 1 1 9 1 1 1 1 0 0\ncpu0 9 1 1 9 1 1 1 1 0 0\ncpu1 5 0 0 5 0 0 0 0 0 0\n");
    assert.strictEqual(S.measure(null, a).total, -1);
    assert.strictEqual(S.measure(null, a).cores[0].usage, -1);
    const m = S.measure(a, b);
    assert.strictEqual(m.total, 50);
    assert.deepStrictEqual(Array.from(m.cores, c => [c.id, c.usage]), [[0, 50], [1, -1]]);
});

test("counters reset by a CPU going offline and back give -1, not a negative", () => {
    const a = S.parseStat("cpu  1000 0 1000 9000 0 0 0 0 0 0\n");
    const b = S.parseStat("cpu  10 0 10 90 0 0 0 0 0 0\n");
    assert.strictEqual(S.measure(a, b).total, -1);
});

test("iowait going backwards never pushes the share past 100", () => {
    const a = S.parseStat("cpu  0 0 0 0 500 0 0 0 0 0\n");
    const b = S.parseStat("cpu  100 0 0 0 400 0 0 0 0 0\n");
    assert.strictEqual(S.measure(a, b).total, 100);
});

test("no time passed: -1", () => {
    const a = S.parseStat("cpu  5 5 5 5 5 5 5 5 0 0\n");
    assert.strictEqual(S.measure(a, a).total, -1);
});

test("cores are named by number, gaps and order included", () => {
    const s = S.parseStat("cpu  1 1 1 1 1 1 1 1 0 0\ncpu2 1 1 1 1 1 1 1 1 0 0\ncpu0 1 1 1 1 1 1 1 1 0 0\nintr 1 2 3\n");
    assert.deepStrictEqual(Array.from(s.cores, c => c.id), [0, 2]);
});

test("busiest core, and nothing when nothing is known", () => {
    assert.deepStrictEqual(S.busiest([{ id: 0, usage: 10 }, { id: 3, usage: 80 }, { id: 4, usage: -1 }]), { id: 3, usage: 80 });
    assert.strictEqual(S.busiest([{ id: 0, usage: -1 }]), null);
});

test("levels: at the threshold counts, critical below warning means equal", () => {
    assert.strictEqual(S.levelFor(-1, 60, 85), 0);
    assert.strictEqual(S.levelFor(59.9, 60, 85), 0);
    assert.strictEqual(S.levelFor(60, 60, 85), 1);
    assert.strictEqual(S.levelFor(85, 60, 85), 2);
    assert.strictEqual(S.levelFor(70, 60, 40), 2);
    assert.strictEqual(S.levelFor(50, 60, 40), 0);
});

test("percent text", () => {
    assert.strictEqual(S.percentText(-1), "--%");
    assert.strictEqual(S.percentText(7.4), "7%");
    assert.strictEqual(S.percentText(99.6), "100%");
});

test("meminfo: in use is total minus available", () => {
    const m = S.parseMeminfo("MemTotal:       16000000 kB\nMemFree:  200000 kB\nMemAvailable:    4000000 kB\nSwapTotal: 8000000 kB\nSwapFree: 6000000 kB\n");
    assert.strictEqual(m.usedKb, 12000000);
    assert.strictEqual(m.swapUsedKb, 2000000);
    assert.strictEqual(S.parseMeminfo(""), null);
});

test("loadavg", () => {
    const l = S.parseLoadavg("18.15 18.98 18.32 4/1919 2201\n");
    assert.deepStrictEqual([l.one, l.five, l.fifteen, l.running, l.tasks], [18.15, 18.98, 18.32, 4, 1919]);
    assert.strictEqual(S.loadText(l), "18.15 · 18.98 · 18.32");
    assert.strictEqual(S.parseLoadavg("garbage"), null);
});

test("sizes", () => {
    assert.strictEqual(S.formatKb(15810932), "15.1 GiB");
    assert.strictEqual(S.formatKb(524288), "512 MiB");
    assert.strictEqual(S.formatKb(209715200), "200 GiB");
});

test("display names: the program, unwrapped, kernel threads as they are", () => {
    assert.deepStrictEqual([
        "/nix/store/x-dsearch-1.6.0/bin/dsearch serve",
        "[kswapd0]",
        "tmux: server   with   spaces",
        "/nix/store/y/bin/..blueman-applet-wrapped-wrapped",
        ""
    ].map(S.displayName), ["dsearch", "[kswapd0]", "tmux", "blueman-applet", "(unknown)"]);
});

test("ps details: spaces in args kept whole, comma decimals read", () => {
    const d = S.parseDetails("2574676 neo  2.4 /nix/store/x/bin/dsearch serve\n   2104 neo 0,1 tmux: server   with   spaces\nnot a line\n");
    assert.deepStrictEqual(Object.keys(d), ["2104", "2574676"]);
    assert.strictEqual(d["2104"].args, "tmux: server   with   spaces");
    assert.strictEqual(d["2104"].pmem, 0.1);
    assert.strictEqual(d["2574676"].user, "neo");
});

test("kill verdicts", () => {
    const e = { pid: "4242", args: "/usr/bin/foo --bar", display: "foo" };
    assert.strictEqual(S.killVerdict(e, "/usr/bin/foo --bar\n", 0, 999), "ok");
    assert.strictEqual(S.killVerdict(e, "", 1, 999), "gone");
    assert.strictEqual(S.killVerdict(e, "", -1, 999), "unchecked");
    assert.strictEqual(S.killVerdict(e, "/usr/bin/other\n", 0, 999), "reused");
    assert.strictEqual(S.killVerdict(e, "/usr/bin/foo --bar\n", 0, 4242), "shell");
    assert.strictEqual(S.killVerdict(e, "/nix/store/q/bin/quickshell -p dms\n", 0, 999), "shell");
    assert.strictEqual(S.killVerdict({ pid: "1", args: "init" }, "init", 0, 999), "invalid");
    assert.strictEqual(S.killVerdict({ pid: "0", args: "x" }, "x", 0, 999), "invalid");
    assert.strictEqual(S.killVerdict({ pid: "-1", args: "x" }, "x", 0, 999), "invalid");
    assert.strictEqual(S.killVerdict({ pid: "12 34", args: "x" }, "x", 0, 999), "invalid");
    assert.ok(S.isShell({ pid: "5", args: "/nix/store/a-quickshell-wrapped-0.3.1/bin/quickshell -p /x" }, 1));
    assert.strictEqual(S.shorten("abcdef", 4), "abc…");
});

test("short args: the program's path cut to the program", () => {
    assert.strictEqual(S.shortArgs("/etc/profiles/per-user/neo/bin/ghostty -e tmux attach-session -t X"), "ghostty -e tmux attach-session -t X");
    assert.strictEqual(S.shortArgs("/nix/store/abc-hyprland-0.55/bin/Hyprland"), "Hyprland");
    assert.strictEqual(S.shortArgs("claude --continue"), "claude --continue");
    assert.strictEqual(S.shortArgs("[kworker/3:1]"), "[kworker/3:1]");
    assert.strictEqual(S.shortArgs(""), "");
});

test("process sample: uptime, self, and a comm with spaces and parentheses", () => {
    const s = S.parseProcSample("s 999\nu 1000.50\n1 120 5 systemd\n42 300 900 tmux: server (x)\nnoise\n");
    assert.strictEqual(s.uptime, 1000.5);
    assert.strictEqual(s.self, "999");
    assert.deepStrictEqual(JSON.parse(JSON.stringify(s.procs["42"])), { ticks: 300, start: 900, comm: "tmux: server (x)" });
    assert.strictEqual(Object.keys(s.procs).length, 2);
});

test("process rate: share of one core over the interval, top first", () => {
    const a = S.parseProcSample("u 100.00\n10 1000 50 busy\n11 500 60 idle\n12 0 70 gone\n");
    // two seconds later: busy used 300 ticks (1.5 cores), idle none, 12 exited,
    // 13 started after the first sample and used 50, 14 was already running
    // but missed by the first sample, 999 is the sampler.
    const b = S.parseProcSample("s 999\nu 102.00\n10 1300 50 busy\n11 500 60 idle\n13 50 10050 new\n14 400 80 missed\n999 3 10190 awk\n");
    const m = S.measureProcs(a, b);
    assert.deepStrictEqual(Array.from(m, r => [r.pid, r.comm, Math.round(r.pcpu * 10) / 10]), [["10", "busy", 150], ["13", "new", 25], ["11", "idle", 0]]);
});

test("process rate: a reused PID counts as a new process", () => {
    const a = S.parseProcSample("u 100.00\n20 5000 50 old\n");
    const b = S.parseProcSample("u 101.00\n20 40 10020 reborn\n");
    const m = S.measureProcs(a, b);
    assert.strictEqual(m.length, 1);
    assert.strictEqual(m[0].comm, "reborn");
    assert.strictEqual(m[0].pcpu, 40);
});

test("process rate: no interval, no rows", () => {
    const a = S.parseProcSample("u 100.00\n20 5000 50 old\n");
    assert.strictEqual(S.measureProcs(null, a).length, 0);
    assert.strictEqual(S.measureProcs(a, a).length, 0);
    assert.strictEqual(S.measureProcs(a, S.parseProcSample("20 5000 50 old\n")).length, 0);
});

test("process rate: ties go to the most CPU used overall", () => {
    const a = S.parseProcSample("u 1.00\n1 10 0 a\n2 90 0 b\n3 50 0 c\n");
    const b = S.parseProcSample("u 2.00\n1 10 0 a\n2 90 0 b\n3 50 0 c\n");
    assert.deepStrictEqual(Array.from(S.measureProcs(a, b), r => r.comm), ["b", "c", "a"]);
});

test("ps details joined to measured rows, exited ones dropped", () => {
    const measured = [{ pid: "10", comm: "busy", pcpu: 150, ticks: 1 }, { pid: "11", comm: "gone", pcpu: 20, ticks: 1 }, { pid: "12", comm: "x", pcpu: 1, ticks: 1 }];
    const details = S.parseDetails("   10 neo   2.5 /nix/store/q-firefox/bin/.firefox-wrapped --new-window\n   12 root  0.0 /usr/bin/x   -y\n");
    const rows = S.joinDetails(measured, details, 5);
    assert.deepStrictEqual(Array.from(rows, r => [r.pid, r.user, r.pcpu, r.pmem, r.display]), [["10", "neo", 150, 2.5, "firefox"], ["12", "root", 1, 0, "x"]]);
    assert.strictEqual(rows[1].args, "/usr/bin/x   -y");
    assert.strictEqual(S.joinDetails(measured, details, 1).length, 1);
});

test("comm names: wrapper dots and a cut-off -wrapped go", () => {
    assert.deepStrictEqual([".ghostty-wrappe", "..blueman-appl", ".firefox-wrapped", "Hyprland", "tmux: server", ".hidden", "kworker/3:1-ev"].map(S.commName),
        ["ghostty", "blueman-appl", "firefox", "Hyprland", "tmux: server", "hidden", "kworker/3:1-ev"]);
});

test("latch: n samples in a row to turn on, n to turn off", () => {
    let l = S.latch(null, false, 2);
    assert.strictEqual(l.on, false);
    l = S.latch(l, true, 2);
    assert.strictEqual(l.on, false, "one hot sample is not enough");
    l = S.latch(l, false, 2);
    l = S.latch(l, true, 2);
    assert.strictEqual(l.on, false, "the run restarts after a quiet sample");
    l = S.latch(l, true, 2);
    assert.strictEqual(l.on, true);
    l = S.latch(l, false, 2);
    assert.strictEqual(l.on, true, "one quiet sample does not clear it");
    l = S.latch(l, false, 2);
    assert.strictEqual(l.on, false);
    assert.strictEqual(S.latch(null, true, 1).on, true);
});

test("pill priority: process, then core, then the total", () => {
    const top = { pid: "7", comm: "cc1", pcpu: 100 };
    const core = { id: 5, usage: 97 };
    let p = S.pillChoice({ processOn: true, coreOn: true, top: top, busiest: core, total: 40, totalLevel: 0 });
    assert.deepStrictEqual([p.kind, p.value, p.level, p.label], ["process", 100, 1, "cc1"]);
    p = S.pillChoice({ processOn: false, coreOn: true, top: top, busiest: core, total: 40, totalLevel: 0 });
    assert.deepStrictEqual([p.kind, p.value, p.level, p.label], ["core", 97, 1, "cpu5"]);
    p = S.pillChoice({ processOn: false, coreOn: false, top: top, busiest: core, total: 70, totalLevel: 1 });
    assert.deepStrictEqual([p.kind, p.value, p.level], ["total", 70, 1]);
    p = S.pillChoice({ processOn: false, coreOn: false, top: null, busiest: null, total: 5, totalLevel: 0 });
    assert.deepStrictEqual([p.kind, p.value, p.level], ["total", 5, 0]);
    // A process alert on a saturated machine is red, not amber.
    p = S.pillChoice({ processOn: true, coreOn: true, top: top, busiest: core, total: 95, totalLevel: 2 });
    assert.deepStrictEqual([p.kind, p.level], ["process", 2]);
    // An alert whose subject is gone falls through to the next one.
    p = S.pillChoice({ processOn: true, coreOn: false, top: null, busiest: core, total: 30, totalLevel: 0 });
    assert.strictEqual(p.kind, "total");
    assert.deepStrictEqual(["process", "core", "total", "?"].map(S.pillIcon), ["terminal", "view_week", "memory", "memory"]);
});

// -------------------------------------------------------------- real data

// The sampler exactly as the service runs it: the template string is taken
// out of ProcessWidgetService.qml and evaluated the way QML would.
function samplerScript() {
    const qml = fs.readFileSync(path.join(__dirname, "..", "ProcessWidgetService.qml"), "utf8");
    const m = /procSampleScript: (`[\s\S]*?`)\n/.exec(qml);
    assert.ok(m, "procSampleScript found");
    return vm.runInNewContext(m[1]);
}

test("live sampler: every process parsed, rates sane, the sampler left out", () => {
    const script = samplerScript();
    // awk exits 2 when a process left between the glob and its read; what it
    // did print is still the answer, which is how the service treats it too.
    const run = () => S.parseProcSample(spawnSync("sh", ["-c", script], { encoding: "utf8", maxBuffer: 64 << 20 }).stdout);
    const a = run();
    // Something to measure: half a second of busy loop in this process.
    const until = Date.now() + 500;
    while (Date.now() < until) { /* spin */ }
    const b = run();
    const nProc = fs.readdirSync("/proc").filter(n => /^\d+$/.test(n)).length;
    const n = Object.keys(b.procs).length;
    assert.ok(b.uptime > a.uptime, "uptime advances");
    assert.ok(Math.abs(n - nProc) <= Math.max(5, nProc * 0.05), n + " parsed vs " + nProc + " in /proc");
    assert.ok(b.self && !b.procs[b.self] || b.procs[b.self].comm === "awk", "self is the awk");
    const m = S.measureProcs(a, b);
    assert.ok(m.every(r => r.pid !== b.self && r.pcpu >= 0), "no sampler, no negatives");
    const me = m.find(r => r.pid === String(process.pid));
    assert.ok(me && me.pcpu > 20, "this busy node process is seen: " + (me ? me.pcpu.toFixed(1) : "missing"));
    console.log("     " + n + " processes; busiest now: " + m.slice(0, 3).map(r => r.comm + " " + r.pcpu.toFixed(0) + "%").join(", "));
});


test("live /proc/stat: two readings 500 ms apart", () => {
    const t0 = fs.readFileSync("/proc/stat", "utf8");
    sleepMs(500);
    const t1 = fs.readFileSync("/proc/stat", "utf8");
    const a = S.parseStat(t0), b = S.parseStat(t1);
    const nCores = (t1.match(/^cpu\d+ /gm) || []).length;
    assert.strictEqual(b.cores.length, nCores, "every cpuN line parsed");
    const m = S.measure(a, b);
    assert.ok(m.total >= 0 && m.total <= 100, "total in range: " + m.total);
    const expected = naiveBusy(t0.split("\n")[0], t1.split("\n")[0]);
    assert.ok(Math.abs(m.total - expected) < 1e-9, m.total + " vs naive " + expected);
    for (const c of m.cores)
        assert.ok(c.usage >= 0 && c.usage <= 100, "cpu" + c.id + " " + c.usage);
    console.log("     " + nCores + " cores, total " + m.total.toFixed(1) + "%, busiest cpu" + S.busiest(m.cores).id + " " + S.busiest(m.cores).usage.toFixed(1) + "%");
});

test("live /proc/meminfo and /proc/loadavg", () => {
    const m = S.parseMeminfo(fs.readFileSync("/proc/meminfo", "utf8"));
    assert.ok(m && m.totalKb > 0 && m.usedKb > 0 && m.usedKb <= m.totalKb);
    const l = S.parseLoadavg(fs.readFileSync("/proc/loadavg", "utf8"));
    assert.ok(l && l.tasks > 0);
    console.log("     memory " + S.formatKb(m.usedKb) + " of " + S.formatKb(m.totalKb) + ", swap " + S.formatKb(m.swapUsedKb) + " of " + S.formatKb(m.swapTotalKb) + ", load " + S.loadText(l));
});

test("ps details for the sampled PIDs, as the service asks for them", () => {
    const pids = fs.readdirSync("/proc").filter(n => /^\d+$/.test(n)).slice(0, 12);
    const r = spawnSync("ps", ["-o", "pid=,user=,pmem=,args=", "ww", "-p", pids.join(",")], { encoding: "utf8" });
    const lines = r.stdout.split("\n").filter(l => l.trim().length > 0);
    const d = S.parseDetails(r.stdout);
    assert.strictEqual(Object.keys(d).length, lines.length, "a row for every line");
    for (const pid of Object.keys(d)) {
        assert.ok(pids.indexOf(pid) >= 0, "only what was asked for: " + pid);
        assert.ok(d[pid].user.length > 0 && isFinite(d[pid].pmem), "row " + pid);
    }
    console.log("     " + lines.length + " of " + pids.length + " PIDs described; e.g. " + Object.keys(d).slice(0, 3).map(p => p + " " + S.displayName(d[p].args)).join(", "));
});

console.log("\n" + passed + " passed" + (process.exitCode ? ", some FAILED" : ""));
