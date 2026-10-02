#!/usr/bin/env node
// The widget's arithmetic and parsing, outside quickshell:
//
//   node tests/procstat.test.js              live /proc and a live `ps`
//   node tests/procstat.test.js saved-ps.txt the same, with a saved ps table
//
// procstat.js is a QML ".pragma library" file; with the pragma line removed it
// is plain JavaScript, run here in a sandbox of its own.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { execFileSync } = require("child_process");

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

test("ps lines: spaces in args kept whole, kernel threads, ps itself skipped", () => {
    const text = [
        "2574676 neo       168  2.4 /nix/store/x-dsearch-1.6.0/bin/dsearch serve",
        "     11 neo      10.0  0.0 ps -eo pid=,user=,pcpu=,pmem=,args= --sort=-pcpu ww",
        "    182 root      3.8  0.0 [kswapd0]",
        "   2104 neo       4,4  0.1 tmux: server   with   spaces",
        "  4242 neo 0.0 0.0 /nix/store/y/bin/..blueman-applet-wrapped-wrapped",
        "",
        "not a process line"
    ].join("\n");
    const rows = S.parseProcesses(text, { limit: 10, skipName: "ps" });
    assert.deepStrictEqual(Array.from(rows, r => r.display), ["dsearch", "[kswapd0]", "tmux", "blueman-applet"]);
    assert.strictEqual(rows[0].pcpu, 168);
    assert.strictEqual(rows[2].pcpu, 4.4);
    assert.strictEqual(rows[2].args, "tmux: server   with   spaces");
    assert.strictEqual(S.parseProcesses(text, { limit: 2, skipName: "ps" }).length, 2);
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

// -------------------------------------------------------------- real data

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

test("ps table: every line parsed, order kept, ps skipped", () => {
    const saved = process.argv[2];
    const text = saved ? fs.readFileSync(saved, "utf8") : execFileSync("ps", ["-eo", "pid=,user=,pcpu=,pmem=,args=", "--sort=-pcpu", "ww"], { encoding: "utf8" });
    const lines = text.split("\n").filter(l => l.trim().length > 0);
    const all = S.parseProcesses(text, { limit: 0 });
    assert.strictEqual(all.length, lines.length, "a row for every line");
    for (let i = 0; i < all.length; i++) {
        const r = all[i];
        assert.ok(/^\d+$/.test(r.pid) && r.user.length > 0 && isFinite(r.pcpu) && isFinite(r.pmem), "row " + i);
        // args is the line's own tail, byte for byte
        assert.ok(lines[i].trimEnd().endsWith(r.args), "args of line " + i);
        if (i > 0)
            assert.ok(all[i - 1].pcpu >= r.pcpu, "still sorted at " + i);
    }
    const top = S.parseProcesses(text, { limit: 8, skipName: "ps" });
    assert.ok(top.length === Math.min(8, all.filter(r => r.display !== "ps").length));
    assert.ok(top.every(r => r.display !== "ps"));
    console.log("     " + all.length + " processes" + (saved ? " (saved)" : "") + "; top: " + top.slice(0, 5).map(r => r.display + " " + r.pcpu + "%").join(", "));
});

console.log("\n" + passed + " passed" + (process.exitCode ? ", some FAILED" : ""));
