// node tests/files.test.js            -- the pure parts of files.js
// node tests/files.test.js <folder>   -- also lists a real folder the way the
//                                        launcher does, and parses that
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const src = fs.readFileSync(path.join(__dirname, "..", "files.js"), "utf8").replace(/^\.pragma.*$/m, "");
const F = new Function(src + "\nreturn { parseListing, search, iconFor, previewable, sizeText, agoText, describe, fileUri };")();

let failed = 0;
let passed = 0;
function check(name, cond, detail) {
    if (cond) {
        passed++;
        return;
    }
    failed++;
    console.log("FAIL", name, detail === undefined ? "" : JSON.stringify(detail));
}

const now = 1790000000000;
const listing = [
    [now / 1000 - 30, 2048, "f", "report.pdf"],
    [now / 1000 - 60, 0, "d", "Invoices"],
    [now / 1000 - 90, 5000, "f", "Invoices/2026-march.pdf"],
    [now / 1000 - 120, 300, "f", "Invoices/old/2025-march.pdf"],
    [now / 1000 - 150, 1e6, "f", "holiday photo.JPG"],
    [now / 1000 - 180, 7e9, "f", "ubuntu.iso.part"],
    [now / 1000 - 200, 12, "f", "name\twith tab.txt"],
    [now / 1000 - 240, 99, "f", "march-notes.md"]
].map(r => r.join("\t")).join("\n") + "\nnot a record\n\n";

const entries = F.parseListing(listing, "/home/u/Downloads/");
check("parses every record and skips junk", entries.length === 8, entries.length);
check("path is folder + relative path", entries[2].path === "/home/u/Downloads/Invoices/2026-march.pdf", entries[2].path);
check("dir and name split", entries[2].dir === "Invoices" && entries[2].name === "2026-march.pdf");
check("a tab inside a name survives", entries[6].name === "name\twith tab.txt", entries[6].name);
check("extension is lowercased", entries[4].ext === "jpg");
check("folders have no extension", entries[1].isDir && entries[1].ext === "");
check("depth counts folders", entries[3].depth === 2 && entries[0].depth === 0);
check("partial download is flagged", entries[5].partial === true && entries[0].partial === false);

const none = F.search(entries, "", 3);
check("no query: newest first, capped", none.length === 3 && none[0].name === "report.pdf");

const march = F.search(entries, "march", 10).map(e => e.rel);
check("name starting with the query wins", march[0] === "march-notes.md", march);
check("shallower before deeper on equal terms", march.indexOf("Invoices/2026-march.pdf") < march.indexOf("Invoices/old/2025-march.pdf"), march);

const both = F.search(entries, "invoices 2026", 10).map(e => e.rel);
check("words may match the folder", both.length === 1 && both[0] === "Invoices/2026-march.pdf", both);
check("case does not matter", F.search(entries, "HOLIDAY", 5).length === 1);
check("extension search", F.search(entries, ".pdf", 10).length === 3);
check("no match is empty", F.search(entries, "zzz", 10).length === 0);

check("icon: folder", F.iconFor(entries[1]) === "folder");
check("icon: pdf", F.iconFor(entries[0]) === "picture_as_pdf");
check("icon: partial wins over type", F.iconFor(entries[5]) === "downloading");
check("icon: image", F.iconFor(entries[4]) === "image");
check("preview only for images Qt reads", F.previewable(entries[4]) && !F.previewable(entries[0]) && !F.previewable(entries[5]));

check("size bytes", F.sizeText(512) === "512 B");
check("size KB", F.sizeText(2048) === "2.0 KB", F.sizeText(2048));
check("size GB", F.sizeText(7e9) === "6.5 GB", F.sizeText(7e9));
check("ago: just now", F.agoText(now - 20000, now) === "just now");
check("ago: minutes", F.agoText(now - 5 * 60000, now) === "5 min ago");
check("ago: yesterday", F.agoText(now - 26 * 3600000, now) === "yesterday");
check("describe nested partial", F.describe(entries[5], now).indexOf("still downloading") !== -1);
check("describe nested file shows its folder", F.describe(entries[2], now).indexOf("Invoices/") === 0, F.describe(entries[2], now));

check("uri encodes spaces and quotes", F.fileUri("/home/u/it's a file#1.pdf") === "file:///home/u/it%27s%20a%20file%231.pdf", F.fileUri("/home/u/it's a file#1.pdf"));

// The launcher's own listing script, run for real against a scratch folder.
const launcher = fs.readFileSync(path.join(__dirname, "..", "DownloadsRunnerLauncher.qml"), "utf8");
const m = /readonly property string _listScript: '([\s\S]*?)'\n/.exec(launcher);
check("listing script found in the launcher", !!m);
if (m) {
    // QML string escapes, the way the engine reads them.
    const script = m[1].replace(/\\\\/g, "\\");
    const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR || "/tmp", "dlrunner-"));
    fs.mkdirSync(path.join(tmp, "sub", "deep", "deeper"), { recursive: true });
    fs.writeFileSync(path.join(tmp, "a file.txt"), "x");
    fs.writeFileSync(path.join(tmp, ".hidden"), "x");
    fs.writeFileSync(path.join(tmp, "sub", "b.pdf"), "xx");
    fs.writeFileSync(path.join(tmp, "sub", "deep", "deeper", "c.png"), "xxx");
    fs.writeFileSync(path.join(tmp, "bad\nname"), "x");
    const run = (depth, hidden) => execFileSync("sh", ["-c", script, "downloads-list", tmp, String(depth), hidden, "5000"], { encoding: "utf8" });
    const shallow = F.parseListing(run(2, "0"), tmp).map(e => e.rel).sort();
    check("depth 2, hidden off, newline names dropped", JSON.stringify(shallow) === JSON.stringify(["a file.txt", "sub", "sub/b.pdf", "sub/deep"]), shallow);
    const all = F.parseListing(run(4, "1"), tmp).map(e => e.rel);
    check("hidden on, deeper", all.indexOf(".hidden") !== -1 && all.indexOf("sub/deep/deeper/c.png") !== -1, all);
    let missingCode = 0;
    try {
        execFileSync("sh", ["-c", script, "downloads-list", path.join(tmp, "nope"), "2", "0", "10"]);
    } catch (e) {
        missingCode = e.status;
    }
    check("a missing folder exits 3", missingCode === 3, missingCode);
    fs.rmSync(tmp, { recursive: true, force: true });

    if (process.argv[2]) {
        const out = execFileSync("sh", ["-c", script, "downloads-list", process.argv[2], "3", "0", "5000"], { encoding: "utf8" });
        const real = F.parseListing(out, process.argv[2]);
        console.log(real.length + " entries in " + process.argv[2] + "; newest: " + real.slice(0, 3).map(e => e.rel).join(" | "));
    }
}

console.log(failed === 0 ? passed + " passed" : failed + " failed, " + passed + " passed");
process.exit(failed === 0 ? 0 : 1);
