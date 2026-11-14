#!/usr/bin/env node
// The plugin's JavaScript outside quickshell:
//
//   node tests/quicknotes.test.js          iCalendar, WebDAV XML, the view, and
//                                          the sync engine against an in-memory
//                                          server that answers like Nextcloud
//   QUICKNOTES_VERBOSE=1 ...               also prints what qmltestrunner said
//   node tests/quicknotes.test.js --live   plus the engine against a real CalDAV
//                                          server: Radicale, started on
//                                          127.0.0.1 for the run and removed
//                                          after (skipped when not installed)
//
// The .js files are QML ".pragma library" files; with the pragma and .import
// lines handled here they are plain JavaScript, each run in a sandbox of its
// own, the way QML loads them.
"use strict";

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const vm = require("vm");
const http = require("http");
const { spawn, spawnSync } = require("child_process");

const DIR = path.join(__dirname, "..");

function load(file, cache) {
    cache = cache || {};
    if (cache[file])
        return cache[file];
    const ctx = {};
    vm.createContext(ctx);
    let src = fs.readFileSync(path.join(DIR, file), "utf8").replace(/^\.pragma library\s*$/m, "");
    src = src.replace(/^\.import\s+"([^"]+)"\s+as\s+(\w+)\s*$/gm, (m, f, name) => {
        ctx[name] = load(f, cache);
        return "";
    });
    vm.runInContext(src, ctx, {
        filename: file
    });
    cache[file] = ctx;
    return ctx;
}

const cache = {};
const ICal = load("ical.js", cache);
const Dav = load("dav.js", cache);
const Sync = load("sync.js", cache);
const View = load("view.js", cache);

// Objects made inside a sandbox have its prototypes; compare them as data.
const plain = x => JSON.parse(JSON.stringify(x));

let passed = 0;
const queue = [];
function test(name, fn) {
    queue.push({
        name,
        fn
    });
}

async function runAll() {
    for (const t of queue) {
        try {
            await t.fn();
            passed++;
            console.log("ok   " + t.name);
        } catch (e) {
            console.log("FAIL " + t.name + "\n     " + (e && e.stack ? e.stack.split("\n").slice(0, 3).join("\n     ") : e));
            process.exitCode = 1;
        }
    }
}

// ================================================================== iCalendar

// What Nextcloud Tasks writes, give or take: a subtask with notes, a due date
// in a time zone, an alarm, categories, a sort order of its own, and a long
// summary folded over two lines.
const NC_TODO = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Nextcloud Tasks v0.16.1",
    "BEGIN:VTIMEZONE",
    "TZID:Europe/Istanbul",
    "BEGIN:STANDARD",
    "TZOFFSETFROM:+0300",
    "TZOFFSETTO:+0300",
    "TZNAME:+03",
    "DTSTART:19700101T000000",
    "END:STANDARD",
    "END:VTIMEZONE",
    "BEGIN:VTODO",
    "UID:7c6a9f22-1d1b-4c21-9c11-2f3d1c0d9e01",
    "CREATED:20261110T081500Z",
    "LAST-MODIFIED:20261112T101010Z",
    "DTSTAMP:20261112T101010Z",
    "SUMMARY:Çarşamba günü kargoyu teslim al\\, sonra İstanbul'daki ofise uğra ve",
    "  faturayı imzala",
    "DESCRIPTION:Kapı kodu: 4411\\nZil çalışmıyor\\; telefon et",
    "RELATED-TO;RELTYPE=PARENT:0f1e2d3c-aaaa-bbbb-cccc-000000000001",
    "DUE;TZID=Europe/Istanbul:20261120T180000",
    "CATEGORIES:Errands,Work",
    "X-APPLE-SORT-ORDER:123456",
    "PRIORITY:5",
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    "TRIGGER;RELATED=START:-PT15M",
    "DESCRIPTION:Reminder",
    "END:VALARM",
    "END:VTODO",
    "END:VCALENDAR",
    ""
].join("\r\n");

test("ical: reads a Nextcloud Tasks to-do", () => {
    const t = ICal.readTask(NC_TODO);
    assert.strictEqual(t.uid, "7c6a9f22-1d1b-4c21-9c11-2f3d1c0d9e01");
    assert.strictEqual(t.summary, "Çarşamba günü kargoyu teslim al, sonra İstanbul'daki ofise uğra ve faturayı imzala");
    assert.strictEqual(t.description, "Kapı kodu: 4411\nZil çalışmıyor; telefon et");
    assert.strictEqual(t.completed, false);
    assert.strictEqual(t.created, Date.UTC(2026, 10, 10, 8, 15, 0));
    assert.strictEqual(t.parent, "0f1e2d3c-aaaa-bbbb-cccc-000000000001");
});

test("ical: marking done changes three properties and the stamps, nothing else", () => {
    const now = Date.UTC(2026, 10, 14, 12, 0, 0);
    const done = ICal.withCompleted(NC_TODO, true, now);
    const t = ICal.readTask(done);
    assert.strictEqual(t.completed, true);
    assert.strictEqual(t.completedAt, now);
    const todo = ICal.findTodo(ICal.parse(done));
    const names = todo.props.map(l => l.split(/[;:]/)[0]);
    for (const keep of ["UID", "CREATED", "SUMMARY", "DESCRIPTION", "RELATED-TO", "DUE", "CATEGORIES", "X-APPLE-SORT-ORDER", "PRIORITY"])
        assert.ok(names.includes(keep), keep + " kept");
    assert.ok(done.includes("DUE;TZID=Europe/Istanbul:20261120T180000"));
    assert.ok(done.includes("STATUS:COMPLETED") && done.includes("PERCENT-COMPLETE:100") && done.includes("COMPLETED:20261114T120000Z"));
    assert.ok(done.includes("LAST-MODIFIED:20261114T120000Z") && !done.includes("LAST-MODIFIED:20261112T101010Z"));
    assert.ok(done.includes("BEGIN:VALARM") && done.includes("TRIGGER;RELATED=START:-PT15M"), "alarm kept");
    assert.ok(done.includes("BEGIN:VTIMEZONE"), "time zone kept");
    // And open again: the three go, the rest stays.
    const undone = ICal.withCompleted(done, false, now + 1000);
    const u = ICal.readTask(undone);
    assert.strictEqual(u.completed, false);
    assert.ok(undone.includes("STATUS:NEEDS-ACTION") && !undone.includes("PERCENT-COMPLETE") && !/^COMPLETED:/m.test(undone));
    assert.strictEqual(u.summary, ICal.readTask(NC_TODO).summary);
});

test("ical: every written line is CRLF-ended and at most 75 octets", () => {
    const text = "Ünlü bir başlık 😀 ".repeat(12) + "\nikinci satır, noktalı; virgüllü \\ ters bölü";
    const ics = ICal.newTodo("abc", text, Date.UTC(2026, 0, 2, 3, 4, 5));
    assert.ok(ics.endsWith("\r\n"));
    for (const line of ics.split("\r\n"))
        assert.ok(Buffer.byteLength(line, "utf8") <= 75, "line too long: " + line);
    assert.ok(!/[^\r]\n/.test(ics), "bare LF");
    const t = ICal.readTask(ics);
    assert.strictEqual(t.summary, ("Ünlü bir başlık 😀 ".repeat(12)).trim());
    assert.strictEqual(t.description, "ikinci satır, noktalı; virgüllü \\ ters bölü");
    assert.strictEqual(t.created, Date.UTC(2026, 0, 2, 3, 4, 5));
    assert.ok(ics.includes("STATUS:NEEDS-ACTION") && ics.includes("UID:abc"));
});

test("ical: what was typed becomes a title and notes", () => {
    assert.deepStrictEqual(plain(ICal.splitText("  \n\nbuy milk  \n\n2 liters\nskimmed\n\n")), {
        summary: "buy milk",
        description: "2 liters\nskimmed"
    });
    assert.deepStrictEqual(plain(ICal.splitText("a b c")), {
        summary: "a",
        description: "b\nc"
    });
    assert.strictEqual(ICal.splitText(" \n \t").summary, "");
});

test("ical: done is a COMPLETED date or STATUS:COMPLETED or CANCELLED", () => {
    const base = body => "BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:x\nSUMMARY:s\n" + body + "END:VTODO\nEND:VCALENDAR\n";
    assert.strictEqual(ICal.readTask(base("STATUS:COMPLETED\n")).completed, true);
    assert.strictEqual(ICal.readTask(base("COMPLETED:20260101T000000Z\n")).completed, true);
    assert.strictEqual(ICal.readTask(base("STATUS:CANCELLED\n")).completed, true);
    assert.strictEqual(ICal.readTask(base("STATUS:IN-PROCESS\nPERCENT-COMPLETE:50\n")).completed, false);
    assert.strictEqual(ICal.readTask("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:e\nEND:VEVENT\nEND:VCALENDAR\n"), null);
});

test("ical: the task itself, not an override of one occurrence", () => {
    const ics = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:r\r\nRECURRENCE-ID:20260105T090000Z\r\nSUMMARY:override\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:r\r\nRRULE:FREQ=WEEKLY\r\nSUMMARY:master\r\nEND:VTODO\r\nEND:VCALENDAR\r\n";
    assert.strictEqual(ICal.readTask(ics).summary, "master");
});

test("ical: text escapes and dates", () => {
    const s = "a\\b;c,d\ne";
    assert.strictEqual(ICal.escapeText(s), "a\\\\b\\;c\\,d\\ne");
    assert.strictEqual(ICal.unescapeText(ICal.escapeText(s)), s);
    assert.strictEqual(ICal.unescapeText("x\\\\n"), "x\\n");
    assert.strictEqual(ICal.parseDate("20261114T093000Z"), Date.UTC(2026, 10, 14, 9, 30, 0));
    assert.strictEqual(ICal.parseDate("20261114"), new Date(2026, 10, 14).getTime());
    assert.strictEqual(ICal.parseDate("nonsense"), 0);
    assert.strictEqual(ICal.formatUtc(Date.UTC(2026, 0, 2, 3, 4, 5)), "20260102T030405Z");
    assert.ok(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(ICal.newUid()));
    const p = ICal.parseLine('ATTENDEE;CN="Doe; John";ROLE=REQ-PARTICIPANT:mailto:john@example.com');
    assert.strictEqual(p.name, "ATTENDEE");
    assert.strictEqual(p.params.CN, "Doe; John");
    assert.strictEqual(p.value, "mailto:john@example.com");
});

// =================================================================== WebDAV

// Nextcloud's answer to PROPFIND Depth 1 on a list, asking for getetag and
// calendar-data, trimmed to two objects: one task, one event.
const NC_MULTISTATUS = `<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/calendars/neo/main/</d:href>
  <d:propstat><d:prop><d:getetag/><cal:calendar-data/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/calendars/neo/main/a%20b.ics</d:href>
  <d:propstat>
   <d:prop>
    <d:getetag>&quot;6a5b8c&quot;</d:getetag>
    <cal:calendar-data>BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VTODO
UID:ab
SUMMARY:Fish &amp; chips &lt;tonight&gt;
END:VTODO
END:VCALENDAR
</cal:calendar-data>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/calendars/neo/main/ev.ics</d:href>
  <d:propstat><d:prop><d:getetag>"e1"</d:getetag><cal:calendar-data><![CDATA[BEGIN:VCALENDAR
BEGIN:VEVENT
UID:ev
END:VEVENT
END:VCALENDAR
]]></cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>`;

test("dav: reads a Nextcloud multistatus", () => {
    const rs = Dav.parseMultistatus(NC_MULTISTATUS);
    assert.strictEqual(rs.length, 3);
    assert.strictEqual(rs[0].href, "/remote.php/dav/calendars/neo/main/");
    assert.strictEqual(Object.keys(rs[0].props).length, 0, "404 propstat is not a property");
    assert.strictEqual(Dav.propText(rs[1], Dav.DAV, "getetag"), '"6a5b8c"');
    const t = ICal.readTask(Dav.propRaw(rs[1], Dav.CALDAV, "calendar-data"));
    assert.strictEqual(t.summary, "Fish & chips <tonight>");
    assert.ok(Dav.propRaw(rs[2], Dav.CALDAV, "calendar-data").includes("BEGIN:VEVENT"), "CDATA");
    assert.strictEqual(Dav.parseMultistatus("<html>nope</html>"), null);
});

test("dav: default namespaces, calendars and component sets", () => {
    const xml = `<?xml version="1.0" encoding="utf-8"?>
<multistatus xmlns="DAV:"><response><href>/neo/main/</href><propstat><prop>
<resourcetype><collection/><C:calendar xmlns:C="urn:ietf:params:xml:ns:caldav"/></resourcetype>
<displayname>Main</displayname>
<supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name="VEVENT"/><comp name="VTODO"/></supported-calendar-component-set>
<current-user-principal><href>/neo/</href></current-user-principal>
</prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response><href>/neo/events/</href><propstat><prop><resourcetype><collection/><calendar xmlns="urn:ietf:params:xml:ns:caldav"/></resourcetype>
<supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name="VEVENT"/></supported-calendar-component-set>
</prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response><href>/neo/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
</multistatus>`;
    const rs = Dav.parseMultistatus(xml);
    assert.strictEqual(rs.length, 3);
    assert.ok(Dav.isCalendar(rs[0]) && Dav.supportsTodo(rs[0]));
    assert.ok(Dav.isCalendar(rs[1]) && !Dav.supportsTodo(rs[1]));
    assert.ok(!Dav.isCalendar(rs[2]));
    assert.strictEqual(Dav.propText(rs[0], Dav.DAV, "displayname"), "Main");
    assert.strictEqual(Dav.propHref(rs[0], Dav.DAV, "current-user-principal"), "/neo/");
});

test("dav: URLs", () => {
    assert.strictEqual(Dav.resolve("https://c.example/remote.php/dav/", "/remote.php/dav/principals/users/neo/"), "https://c.example/remote.php/dav/principals/users/neo/");
    assert.strictEqual(Dav.resolve("https://c.example/a/b/", "c.ics"), "https://c.example/a/b/c.ics");
    assert.strictEqual(Dav.resolve("https://c.example/a/b/", "https://other.example/x"), "https://other.example/x");
    assert.ok(Dav.samePath("https://c.example/neo/m%61in/", "/neo/main"));
    assert.ok(!Dav.samePath("https://c.example/neo/main/x.ics", "/neo/main/"));
    assert.strictEqual(Dav.lastSegment("https://c.example/neo/my%20list/"), "my list");
    assert.deepStrictEqual(plain(Dav.startUrls("cloud.example.com")), ["https://cloud.example.com/remote.php/dav/", "https://cloud.example.com/.well-known/caldav", "https://cloud.example.com/"]);
    assert.deepStrictEqual(plain(Dav.startUrls("https://example.com/nextcloud/")), ["https://example.com/nextcloud/remote.php/dav/", "https://example.com/nextcloud/.well-known/caldav", "https://example.com/nextcloud/"]);
    assert.deepStrictEqual(plain(Dav.startUrls("https://c.example/remote.php/dav/calendars/neo/main")), ["https://c.example/remote.php/dav/calendars/neo/main/"]);
    assert.deepStrictEqual(plain(Dav.startUrls("  ")), []);
    for (const [u, p] of [["neo", "secret"], ["ünal", "şifre-🔑"], ["a", ""]])
        assert.strictEqual(Dav.basicAuth(u, p), "Basic " + Buffer.from(u + ":" + p, "utf8").toString("base64"));
    assert.ok(Dav.propfind([[Dav.DAV, "getetag"], [Dav.CALDAV, "calendar-data"], [Dav.CS, "getctag"]]).includes("<d:getetag/><c:calendar-data/><cs:getctag/>"));
});

// ===================================================================== view

const T = (uid, summary, created, more) => Object.assign({
    uid,
    summary,
    description: "",
    completed: false,
    completedAt: 0,
    created,
    modified: created,
    parent: ""
}, more || {});

test("view: search folds case, accents and the Turkish i", () => {
    const t = T("1", "İstanbul'da çay iç", 1, {
        description: "Kadıköy ŞUBESİ"
    });
    assert.ok(View.matches(t, "istanbul"));
    assert.ok(View.matches(t, "CAY ic"));
    assert.ok(View.matches(t, "kadikoy subesi"));
    assert.ok(!View.matches(t, "ankara"));
    assert.ok(View.matches(t, "   "));
});

test("view: done tasks stay for a while, or always, or not at all", () => {
    const now = Date.UTC(2026, 10, 14, 12);
    const open = T("o", "open", 1);
    const recent = T("r", "recent", 1, {
        completed: true,
        completedAt: now - 3600000
    });
    const old = T("x", "old", 1, {
        completed: true,
        completedAt: now - 3 * 86400000
    });
    const vis = (t, h, keep) => View.isVisible(t, now, h, keep);
    assert.ok(vis(open, 0) && vis(open, 24));
    assert.ok(vis(recent, 24) && !vis(old, 24));
    assert.ok(vis(old, -1) && !vis(recent, 0));
    assert.ok(vis(old, 0, {
        x: true
    }), "marked in this sitting");
});

test("view: oldest at the top, subtasks under their parent, newest next to the field", () => {
    const tasks = [T("c", "child", 30, {
            parent: "p"
        }), T("n", "newest", 50), T("p", "parent", 10), T("g", "grandchild", 40, {
            parent: "c"
        }), T("o", "orphan", 20, {
            parent: "gone"
        }), T("y1", "cycle a", 5, {
            parent: "y2"
        }), T("y2", "cycle b", 6, {
            parent: "y1"
        })];
    const order = View.order(tasks).map(t => t.uid + ":" + t.depth);
    assert.deepStrictEqual(plain(order), ["p:0", "c:1", "g:2", "o:0", "n:0", "y1:0", "y2:1"]);
    const rows = View.rows(tasks, {
        query: null,
        nowMs: 100,
        keepDoneHours: 24,
        keep: {}
    });
    assert.strictEqual(rows[0].uid, "y2", "index 0 is the bottom row");
    const found = View.rows(tasks, {
        query: "child",
        nowMs: 100,
        keepDoneHours: 0,
        keep: {}
    });
    assert.deepStrictEqual(plain(found.map(r => r.uid)), ["g", "c"]);
});

test("view: ages and the sync line", () => {
    const now = Date.UTC(2026, 10, 14, 12);
    assert.strictEqual(View.age(now - 30000, now), "now");
    assert.strictEqual(View.age(now - 5 * 60000, now), "5m");
    assert.strictEqual(View.age(now - 3 * 3600000, now), "3h");
    assert.strictEqual(View.age(now - 2 * 86400000, now), "2d");
    assert.strictEqual(View.age(now - 15 * 86400000, now), "2w");
    assert.strictEqual(View.age(Date.UTC(2025, 2, 12, 12), now), "12 Mar 2025");
    const st = (o) => Object.assign({
        running: "",
        lastSyncMs: 0,
        lastError: "",
        waiting: 0,
        failed: 0
    }, o);
    assert.strictEqual(View.syncLine(st({
        lastSyncMs: now - 120000
    }), true, now).text, "Synced 2 min ago");
    assert.strictEqual(View.syncLine(st({
        waiting: 2
    }), true, now).text, "2 changes waiting to be sent");
    assert.deepStrictEqual(plain(View.syncLine(st({
        lastError: "No answer from the server",
        waiting: 1
    }), true, now)), {
        text: "No answer from the server · 1 change waiting to be sent",
        error: true
    });
    assert.ok(View.syncLine(st({}), false, now).text.startsWith("Kept here only"));
});

// ============================================= the engine, against a fake server

// An in-memory CalDAV server that answers the way Nextcloud's sabre/dav does:
// principal and calendar home under /remote.php/dav, calendar-data inside
// PROPFIND, a ctag that moves on every change, ETags, If-Match and
// If-None-Match. `calendarDataInPropfind: false` makes it a server that only
// hands objects out by GET.
function fakeServer(opts) {
    opts = opts || {};
    const s = {
        user: "neo",
        password: "app-pass",
        offline: false,
        calendarDataInPropfind: opts.calendarDataInPropfind !== false,
        lists: {
            main: {
                name: opts.mainName || "Main",
                comps: ["VTODO"],
                objects: {},
                ctag: 1
            },
            personal: {
                name: "Personal",
                comps: ["VEVENT"],
                objects: {},
                ctag: 1
            },
            work: {
                name: "Work",
                comps: ["VEVENT", "VTODO"],
                objects: {},
                ctag: 1
            }
        },
        log: [],
        etagSeq: 1
    };
    const BASE = "/remote.php/dav";
    const ms = responses => '<?xml version="1.0"?>\n<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">' + responses.join("") + "</d:multistatus>";
    const resp = (href, props) => "<d:response><d:href>" + href + "</d:href><d:propstat><d:prop>" + props + "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>";
    const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const listProps = (key, l) => "<d:resourcetype><d:collection/><cal:calendar/></d:resourcetype><d:displayname>" + esc(l.name) + "</d:displayname><cal:supported-calendar-component-set>" + l.comps.map(c => '<cal:comp name="' + c + '"/>').join("") + "</cal:supported-calendar-component-set>";

    s.put = (list, name, ics) => {
        const etag = '"' + (s.etagSeq++) + '"';
        s.lists[list].objects[name] = {
            ics,
            etag
        };
        s.lists[list].ctag++;
        return etag;
    };

    s.handle = req => {
        const u = new URL(req.url);
        const p = decodeURIComponent(u.pathname);
        s.log.push(req.method + " " + p);
        const auth = req.headers.Authorization || "";
        if (auth !== "Basic " + Buffer.from(s.user + ":" + s.password).toString("base64"))
            return {
                status: 401,
                text: ""
            };
        const want = name => req.body.includes(":" + name + "/>");
        if (req.method === "PROPFIND") {
            const depth = req.headers.Depth;
            if (p === BASE + "/")
                return {
                    status: 207,
                    text: ms([resp(BASE + "/", "<d:current-user-principal><d:href>" + BASE + "/principals/users/neo/</d:href></d:current-user-principal><d:resourcetype><d:collection/></d:resourcetype>")])
                };
            if (p === BASE + "/principals/users/neo/")
                return {
                    status: 207,
                    text: ms([resp(p, "<cal:calendar-home-set><d:href>" + BASE + "/calendars/neo/</d:href></cal:calendar-home-set>")])
                };
            if (p === BASE + "/calendars/neo/") {
                const out = [resp(p, "<d:resourcetype><d:collection/></d:resourcetype>")];
                if (depth === "1") {
                    out.push(resp(p + "inbox/", "<d:resourcetype><d:collection/><cal:schedule-inbox/></d:resourcetype>"));
                    for (const key in s.lists)
                        out.push(resp(p + key + "/", listProps(key, s.lists[key])));
                }
                return {
                    status: 207,
                    text: ms(out)
                };
            }
            const m = /^\/remote\.php\/dav\/calendars\/neo\/([^\/]+)\/$/.exec(p);
            if (m && s.lists[m[1]]) {
                const l = s.lists[m[1]];
                const own = (want("getctag") ? "<cs:getctag>" + l.ctag + "</cs:getctag>" : "") + (want("sync-token") ? "<d:sync-token>http://sabre.io/ns/sync/" + l.ctag + "</d:sync-token>" : "") + (want("resourcetype") || want("displayname") ? listProps(m[1], l) : "");
                const out = [resp(p, own)];
                if (depth === "1") {
                    for (const name in l.objects)
                        out.push(resp(p + encodeURIComponent(name), "<d:getetag>" + esc(l.objects[name].etag) + "</d:getetag>" + (s.calendarDataInPropfind && want("calendar-data") ? "<cal:calendar-data>" + esc(l.objects[name].ics.replace(/\r/g, "")) + "</cal:calendar-data>" : "")));
                }
                return {
                    status: 207,
                    text: ms(out)
                };
            }
            return {
                status: 404,
                text: ""
            };
        }
        const m = /^\/remote\.php\/dav\/calendars\/neo\/([^\/]+)\/([^\/]+)$/.exec(p);
        if (!m || !s.lists[m[1]])
            return {
                status: 404,
                text: ""
            };
        const l = s.lists[m[1]];
        const obj = l.objects[m[2]];
        if (req.method === "GET")
            return obj ? {
                status: 200,
                text: obj.ics,
                etag: obj.etag
            } : {
                status: 404,
                text: ""
            };
        if (req.method === "PUT") {
            if (req.headers["If-None-Match"] === "*" && obj)
                return {
                    status: 412,
                    text: ""
                };
            if (req.headers["If-Match"] && (!obj || obj.etag !== req.headers["If-Match"]))
                return {
                    status: 412,
                    text: ""
                };
            const etag = s.put(m[1], m[2], req.body);
            return {
                status: obj ? 204 : 201,
                text: "",
                etag
            };
        }
        if (req.method === "DELETE") {
            if (!obj)
                return {
                    status: 404,
                    text: ""
                };
            delete l.objects[m[2]];
            l.ctag++;
            return {
                status: 204,
                text: ""
            };
        }
        return {
            status: 405,
            text: ""
        };
    };

    // The engine's env.request: answers on a later tick, like a network.
    s.request = (req, done) => {
        setImmediate(() => {
            if (s.offline)
                return done({
                    status: 0,
                    error: "Connection refused"
                });
            const r = s.handle(req);
            if (s.dropAnswers) {
                s.dropAnswers--;
                return done({
                    status: 0,
                    error: "Connection reset"
                });
            }
            done({
                status: r.status,
                text: r.text || "",
                etag: r.etag || ""
            });
        });
    };
    return s;
}

// An engine on a fake clock, with run() resolving when the job it starts ends.
function harness(server, request) {
    const h = {
        clock: Date.UTC(2026, 10, 14, 9, 0, 0),
        changes: 0,
        finished: []
    };
    let waiter = null;
    h.engine = Sync.createEngine({
        request: request || server.request,
        now: () => h.clock,
        changed: () => h.changes++,
        finished: (kind, err) => {
            h.finished.push({
                kind,
                err: err ? plain(err) : null
            });
            if (waiter) {
                const w = waiter;
                waiter = null;
                w({
                    kind,
                    err: err ? plain(err) : null
                });
            }
        }
    });
    h.run = kind => new Promise(resolve => {
        waiter = resolve;
        if (kind === "push")
            h.engine.push();
        else
            h.engine.sync(kind === "manual");
    });
    h.tasks = () => plain(h.engine.tasks()).sort((a, b) => a.created - b.created || a.summary.localeCompare(b.summary));
    return h;
}

const SERVER = "https://cloud.example.com";
const account = (more) => Object.assign({
    server: SERVER,
    user: "neo",
    password: "app-pass",
    listName: "main"
}, more || {});

test("engine: finds the list by name, Nextcloud's way, and reads it", async () => {
    const srv = fakeServer();
    srv.put("main", "t1.ics", ICal.newTodo("t1", "first\nwith notes", Date.UTC(2026, 10, 1)));
    srv.put("main", "t2.ics", ICal.withCompleted(ICal.newTodo("t2", "second", Date.UTC(2026, 10, 2)), true, Date.UTC(2026, 10, 3)));
    const h = harness(srv);
    h.engine.configure(account());
    const r = await h.run("sync");
    assert.strictEqual(r.err, null);
    const st = plain(h.engine.status());
    assert.strictEqual(st.listUrl, SERVER + "/remote.php/dav/calendars/neo/main/");
    assert.strictEqual(st.listTitle, "Main");
    assert.strictEqual(st.lastSyncMs, h.clock);
    const tasks = h.tasks();
    assert.deepStrictEqual(tasks.map(t => [t.uid, t.summary, t.description, t.completed, t.pending]), [["t1", "first", "with notes", false, false], ["t2", "second", "", true, false]]);
    // Nothing changed: one PROPFIND for the ctag, no second read.
    srv.log = [];
    await h.run("sync");
    assert.deepStrictEqual(srv.log, ["PROPFIND /remote.php/dav/calendars/neo/main/"]);
});

test("engine: a task typed here is shown at once and sent in the background", async () => {
    const srv = fakeServer();
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    const uid = h.engine.add("call the bank\nabout the card");
    assert.ok(uid);
    let t = h.tasks();
    assert.strictEqual(t.length, 1);
    assert.strictEqual(t[0].pending, true, "waiting to be sent");
    assert.strictEqual(plain(h.engine.status()).waiting, 1);
    srv.log = [];
    const r = await h.run("push");
    assert.strictEqual(r.err, null);
    assert.deepStrictEqual(srv.log, ["PUT /remote.php/dav/calendars/neo/main/" + uid + ".ics"]);
    const onServer = ICal.readTask(srv.lists.main.objects[uid + ".ics"].ics);
    assert.strictEqual(onServer.summary, "call the bank");
    assert.strictEqual(onServer.description, "about the card");
    t = h.tasks();
    assert.strictEqual(t[0].pending, false);
    assert.strictEqual(plain(h.engine.status()).waiting, 0);
    assert.strictEqual(h.engine.add("  \n "), "", "nothing typed, nothing added");
});

test("engine: marking done is a PUT on the ETag it read, keeping the rest", async () => {
    const srv = fakeServer();
    srv.put("main", "nc.ics", NC_TODO);
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    const uid = "7c6a9f22-1d1b-4c21-9c11-2f3d1c0d9e01";
    assert.ok(h.engine.setDone(uid, true));
    assert.strictEqual(h.tasks()[0].completed, true, "shown done at once");
    srv.log = [];
    await h.run("push");
    assert.deepStrictEqual(srv.log, ["PUT /remote.php/dav/calendars/neo/main/nc.ics"], "no GET: the ETag was known");
    const ics = srv.lists.main.objects["nc.ics"].ics;
    assert.ok(ics.includes("STATUS:COMPLETED") && ics.includes("CATEGORIES:Errands,Work") && ics.includes("BEGIN:VALARM"));
    assert.strictEqual(ICal.readTask(ics).completedAt, h.clock);
    // Back and forth before sending: nothing to send at all.
    h.engine.setDone(uid, false);
    h.engine.setDone(uid, true);
    assert.strictEqual(plain(h.engine.status()).waiting, 0);
    assert.strictEqual(h.engine.setDone("no-such-task", true), false);
});

test("engine: changed on the server meanwhile -- read again, then mark", async () => {
    const srv = fakeServer();
    srv.put("main", "x.ics", ICal.newTodo("x", "original", Date.UTC(2026, 10, 1)));
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    // Someone renames it on the phone; this side still holds the old ETag.
    srv.put("main", "x.ics", ICal.newTodo("x", "renamed on the phone", Date.UTC(2026, 10, 1)));
    h.engine.setDone("x", true);
    srv.log = [];
    const r = await h.run("push");
    assert.strictEqual(r.err, null);
    assert.deepStrictEqual(srv.log, ["PUT /remote.php/dav/calendars/neo/main/x.ics", "GET /remote.php/dav/calendars/neo/main/x.ics", "PUT /remote.php/dav/calendars/neo/main/x.ics"]);
    const t = ICal.readTask(srv.lists.main.objects["x.ics"].ics);
    assert.strictEqual(t.summary, "renamed on the phone", "their change kept");
    assert.strictEqual(t.completed, true, "ours applied");
});

test("engine: a delete waits out its undo time, and Ctrl+Z takes it back", async () => {
    const srv = fakeServer();
    srv.put("main", "a.ics", ICal.newTodo("a", "keep me", Date.UTC(2026, 10, 1)));
    srv.put("main", "b.ics", ICal.newTodo("b", "delete me", Date.UTC(2026, 10, 2)));
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    assert.ok(h.engine.remove("a"));
    assert.deepStrictEqual(h.tasks().map(t => t.uid), ["b"], "gone from the list at once");
    srv.log = [];
    await h.run("push");
    assert.deepStrictEqual(srv.log, [], "not sent inside the undo time");
    assert.ok(h.engine.canUndo());
    assert.strictEqual(h.engine.undoRemove(), "a");
    assert.deepStrictEqual(h.tasks().map(t => t.uid), ["a", "b"]);
    assert.strictEqual(plain(h.engine.status()).waiting, 0);
    // This time for real.
    h.engine.remove("b");
    assert.ok(plain(h.engine.status()).nextDueMs > h.clock);
    h.clock += Sync.UNDO_MS + 1;
    assert.ok(!h.engine.canUndo());
    assert.strictEqual(h.engine.undoRemove(), "");
    await h.run("push");
    assert.deepStrictEqual(srv.log, ["DELETE /remote.php/dav/calendars/neo/main/b.ics"]);
    assert.ok(!srv.lists.main.objects["b.ics"]);
});

test("engine: changes made before anything was sent are merged first", async () => {
    const srv = fakeServer();
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    const a = h.engine.add("typed and done");
    h.engine.setDone(a, true);
    const b = h.engine.add("typed and deleted");
    h.engine.remove(b);
    assert.deepStrictEqual(h.tasks().map(t => [t.summary, t.completed]), [["typed and done", true]]);
    srv.log = [];
    await h.run("push");
    assert.deepStrictEqual(srv.log, ["PUT /remote.php/dav/calendars/neo/main/" + a + ".ics"], "one PUT, already done; the deleted one never left");
    assert.strictEqual(ICal.readTask(srv.lists.main.objects[a + ".ics"].ics).completed, true);
    // Undoing the delete of one never sent brings back its create.
    assert.strictEqual(h.engine.undoRemove(), b);
    await h.run("push");
    assert.ok(srv.lists.main.objects[b + ".ics"]);
});

test("engine: offline, everything waits; back online, it all goes", async () => {
    const srv = fakeServer();
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    srv.offline = true;
    const a = h.engine.add("one");
    const b = h.engine.add("two");
    let r = await h.run("push");
    assert.strictEqual(r.err.kind, "retry");
    assert.strictEqual(h.tasks().length, 2);
    assert.strictEqual(plain(h.engine.status()).waiting, 2);
    assert.strictEqual(plain(h.engine.status()).lastError, r.err.message);
    srv.offline = false;
    r = await h.run("sync");
    assert.strictEqual(r.err, null);
    assert.ok(srv.lists.main.objects[a + ".ics"] && srv.lists.main.objects[b + ".ics"]);
    assert.strictEqual(plain(h.engine.status()).waiting, 0);
    assert.strictEqual(plain(h.engine.status()).lastError, "");
});

test("engine: the answer to a create is lost -- the retry finds it there", async () => {
    const srv = fakeServer();
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    const uid = h.engine.add("lost answer");
    srv.dropAnswers = 1;
    let r = await h.run("push");
    assert.strictEqual(r.err.kind, "retry");
    assert.ok(srv.lists.main.objects[uid + ".ics"], "it did arrive");
    // Marked done meanwhile; the retry's If-None-Match gets a 412.
    h.engine.setDone(uid, true);
    srv.log = [];
    r = await h.run("push");
    assert.strictEqual(r.err, null);
    assert.deepStrictEqual(srv.log, ["PUT /remote.php/dav/calendars/neo/main/" + uid + ".ics", "GET /remote.php/dav/calendars/neo/main/" + uid + ".ics", "PUT /remote.php/dav/calendars/neo/main/" + uid + ".ics"]);
    assert.strictEqual(ICal.readTask(srv.lists.main.objects[uid + ".ics"].ics).completed, true, "the mark was not lost");
    assert.strictEqual(plain(h.engine.status()).waiting, 0);
});

test("engine: a wrong password stops, and says so", async () => {
    const srv = fakeServer();
    const h = harness(srv);
    h.engine.configure(account({
        password: "wrong"
    }));
    const r = await h.run("sync");
    assert.strictEqual(r.err.kind, "auth");
    assert.strictEqual(srv.log.length, 1, "one try, not one per candidate address");
    assert.ok(/user name and app password/.test(plain(h.engine.status()).lastError));
});

test("engine: no list by that name names the lists there are", async () => {
    const srv = fakeServer();
    const h = harness(srv);
    h.engine.configure(account({
        listName: "groceries"
    }));
    const r = await h.run("sync");
    assert.strictEqual(r.err.kind, "config");
    assert.strictEqual(r.err.message, "No task list named \"groceries\" (there is Main, Work)", "event-only calendars and the inbox left out");
    // Matched ignoring case, by name or by address.
    for (const name of ["work", "WORK", "Work"]) {
        const h2 = harness(fakeServer());
        h2.engine.configure(account({
            listName: name
        }));
        assert.strictEqual((await h2.run("sync")).err, null);
        assert.strictEqual(plain(h2.engine.status()).listUrl, SERVER + "/remote.php/dav/calendars/neo/work/");
    }
});

test("engine: a list's own link as the server address", async () => {
    const srv = fakeServer();
    srv.put("work", "w.ics", ICal.newTodo("w", "from the link", 1));
    const h = harness(srv);
    h.engine.configure(account({
        server: SERVER + "/remote.php/dav/calendars/neo/work/",
        listName: "ignored"
    }));
    assert.strictEqual((await h.run("sync")).err, null);
    assert.strictEqual(plain(h.engine.status()).listUrl, SERVER + "/remote.php/dav/calendars/neo/work/");
    assert.deepStrictEqual(h.tasks().map(t => t.summary), ["from the link"]);
});

test("engine: a server without calendar-data in PROPFIND -- GET what changed", async () => {
    const srv = fakeServer({
        calendarDataInPropfind: false
    });
    srv.put("main", "a.ics", ICal.newTodo("a", "alpha", 1));
    srv.put("main", "b.ics", ICal.newTodo("b", "beta", 2));
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    assert.deepStrictEqual(h.tasks().map(t => t.summary), ["alpha", "beta"]);
    srv.put("main", "b.ics", ICal.newTodo("b", "beta, edited", 2));
    srv.log = [];
    await h.run("sync");
    assert.deepStrictEqual(srv.log, ["PROPFIND /remote.php/dav/calendars/neo/main/", "PROPFIND /remote.php/dav/calendars/neo/main/", "GET /remote.php/dav/calendars/neo/main/b.ics"], "only the changed one fetched");
    assert.deepStrictEqual(h.tasks().map(t => t.summary), ["alpha", "beta, edited"]);
});

test("engine: tasks deleted elsewhere disappear; events in the list are not tasks", async () => {
    const srv = fakeServer();
    srv.put("work", "t.ics", ICal.newTodo("t", "a task", 1));
    srv.put("work", "e.ics", "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:e\r\nSUMMARY:meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n");
    const h = harness(srv);
    h.engine.configure(account({
        listName: "work"
    }));
    await h.run("sync");
    assert.deepStrictEqual(h.tasks().map(t => t.summary), ["a task"]);
    delete srv.lists.work.objects["t.ics"];
    srv.lists.work.ctag++;
    await h.run("sync");
    assert.deepStrictEqual(h.tasks(), []);
});

test("engine: what it keeps survives a restart; another list starts afresh", async () => {
    const srv = fakeServer();
    srv.put("main", "a.ics", ICal.newTodo("a", "alpha", 1));
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    srv.offline = true;
    const typed = h.engine.add("typed offline");
    await h.run("push");
    const saved = JSON.parse(JSON.stringify(h.engine.snapshot()));

    // A restart: restored before any network, the list is all there.
    const h2 = harness(srv);
    h2.engine.restore(saved);
    h2.engine.configure(account());
    assert.deepStrictEqual(h2.tasks().map(t => [t.summary, t.pending]), [["alpha", false], ["typed offline", true]]);
    srv.offline = false;
    srv.log = [];
    await h2.run("sync");
    assert.strictEqual(srv.log[0], "PUT /remote.php/dav/calendars/neo/main/" + typed + ".ics", "no discovery again");

    // Pointed at another list: the old list's tasks go, unsent typing stays.
    srv.offline = true;
    h2.engine.add("for whichever list");
    h2.engine.configure(account({
        listName: "work"
    }));
    assert.deepStrictEqual(h2.tasks().map(t => t.summary), ["for whichever list"]);
    srv.offline = false;
    await h2.run("sync");
    assert.deepStrictEqual(Object.values(srv.lists.work.objects).map(o => ICal.readTask(o.ics).summary), ["for whichever list"]);
    h2.engine.restore({
        version: 99
    });
    assert.strictEqual(h2.tasks().length, 1, "an unknown version is ignored");
});

test("engine: a refusal for good marks that one and goes on with the rest", async () => {
    const srv = fakeServer();
    const h = harness(srv);
    h.engine.configure(account());
    await h.run("sync");
    const bad = h.engine.add("refused");
    const good = h.engine.add("accepted");
    const handle = srv.handle;
    srv.handle = req => req.url.includes(bad) ? {
        status: 403,
        text: ""
    } : handle(req);
    const r = await h.run("push");
    assert.strictEqual(r.err, null);
    assert.ok(srv.lists.main.objects[good + ".ics"]);
    const t = h.tasks().find(x => x.uid === bad);
    assert.strictEqual(t.failed, "Adding a task: not allowed (a list shared read-only?)");
    assert.deepStrictEqual(plain(h.engine.status()).failed, 1);
    // Tried again only when asked for by hand.
    srv.log = [];
    await h.run("sync");
    assert.ok(!srv.log.some(l => l.includes(bad)));
    srv.handle = handle;
    await h.run("manual");
    assert.ok(srv.lists.main.objects[bad + ".ics"]);
    assert.strictEqual(plain(h.engine.status()).failed, 0);
});

test("engine: not set up -- it says so and sends nothing", async () => {
    const srv = fakeServer();
    const h = harness(srv);
    h.engine.configure(account({
        password: ""
    }));
    h.engine.add("kept here");
    const r = await h.run("sync");
    assert.strictEqual(r.err.kind, "config");
    assert.deepStrictEqual(srv.log, []);
    assert.strictEqual(h.tasks().length, 1);
});

// ================================================ the window, by its keys

test("card: the keys, pressed for real under qmltestrunner", () => {
    const qt = qtDeclarative();
    if (!qt) {
        console.log("     (skipped: no qtdeclarative for quickshell found)");
        return;
    }
    const r = runQmlTest(qt, path.join(__dirname, "qml", "CardTest.qml"), {
        "FakeService.qml": fs.readFileSync(path.join(__dirname, "qml", "FakeService.qml"), "utf8")
    }, [path.join(__dirname, "qml", "stubs")]);
    assert.ok(r.ok, r.out.split("\n").filter(l => /^(FAIL|Totals|   Actual|   Expected|   Loc)|rror|is not|Cannot/.test(l)).join("\n"));
});

// ===================================================== live: a real CalDAV server

// The qtdeclarative quickshell is built on, for qmltestrunner -- found the
// way scripts/test-plugin-all.sh finds it -- or "" when there is none.
function qtDeclarative() {
    const out = spawnSync("sh", ["-c", [
        'QS="$(readlink -f "$(command -v quickshell 2>/dev/null)" 2>/dev/null)" || exit 0',
        'for b in "$(dirname "$QS")/.quickshell-wrapped" "$QS"; do',
        '  [ -f "$b" ] || continue',
        '  ldd "$b" 2>/dev/null | sed -n "s|.*=> \\(/nix/store/[^/]*qtdeclarative[^/]*\\)/lib/libQt6Quick\\.so.*|\\1|p" | head -1',
        'done'
    ].join("\n")], {
        encoding: "utf8"
    });
    const dir = (out.stdout || "").split("\n").map(l => l.trim()).find(Boolean) || "";
    return dir && fs.existsSync(dir + "/bin/qmltestrunner") ? dir : "";
}

// Runs one QML TestCase file from a scratch folder holding the plugin's
// files, plus `extra` files ({ name: text }) -> { ok, out }.
function runQmlTest(qt, testFile, extra, imports) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "quicknotes-qml-"));
    try {
        for (const f of fs.readdirSync(DIR)) {
            if (/\.(js|qml)$/.test(f))
                fs.copyFileSync(path.join(DIR, f), path.join(dir, f));
        }
        for (const name in extra || {})
            fs.writeFileSync(path.join(dir, name), extra[name]);
        const target = path.join(dir, "tst_" + path.basename(testFile));
        fs.copyFileSync(testFile, target);
        const args = ["-import", qt + "/lib/qt-6/qml"];
        for (const i of imports || [])
            args.push("-import", i);
        args.push("-input", target);
        const r = spawnSync(qt + "/bin/qmltestrunner", args, {
            encoding: "utf8",
            timeout: 120000,
            env: Object.assign({}, process.env, {
                QT_QPA_PLATFORM: "offscreen"
            })
        });
        const out = (r.stdout || "") + (r.stderr || "");
        if (process.env.QUICKNOTES_VERBOSE)
            console.log(out);
        return {
            ok: /^Totals: \d+ passed, 0 failed/m.test(out),
            out
        };
    } finally {
        fs.rmSync(dir, {
            recursive: true,
            force: true
        });
    }
}


function radicaleBin() {
    const which = spawnSync("sh", ["-c", "command -v radicale"], {
        encoding: "utf8"
    });
    if (which.status === 0 && which.stdout.trim())
        return which.stdout.trim();
    try {
        const hit = fs.readdirSync("/nix/store").filter(d => /^[a-z0-9]{32}-radicale-\d[^\/]*$/.test(d) && !d.endsWith(".drv")).map(d => "/nix/store/" + d + "/bin/radicale").find(f => fs.existsSync(f));
        return hit || "";
    } catch (e) {
        return "";
    }
}

// The engine's env.request over node's http, following redirects with the
// method kept, the way Qt's XMLHttpRequest does.
function httpRequest(req, done) {
    const go = (url, hops) => {
        const u = new URL(url);
        const headers = Object.assign({}, req.headers);
        if (req.body && req.method !== "GET" && req.method !== "DELETE")
            headers["Content-Length"] = Buffer.byteLength(req.body);
        const r = http.request({
            method: req.method,
            hostname: u.hostname,
            port: u.port,
            path: u.pathname + u.search,
            headers
        }, res => {
            let text = "";
            res.setEncoding("utf8");
            res.on("data", c => text += c);
            res.on("end", () => {
                if ([301, 302, 307, 308].includes(res.statusCode) && res.headers.location && hops < 5)
                    return go(new URL(res.headers.location, url).toString(), hops + 1);
                done({
                    status: res.statusCode,
                    text,
                    etag: res.headers.etag || ""
                });
            });
        });
        r.on("error", e => done({
            status: 0,
            error: e.message
        }));
        r.setTimeout(10000, () => r.destroy(new Error("timed out")));
        if (req.body && req.method !== "GET" && req.method !== "DELETE")
            r.write(req.body);
        r.end();
    };
    go(req.url, 0);
}

function raw(method, url, headers, body) {
    return new Promise(resolve => httpRequest({
        method,
        url,
        headers: Object.assign({
            "Authorization": Dav.basicAuth("neo", "secret")
        }, headers || {}),
        body: body || ""
    }, resolve));
}

async function live() {
    const bin = radicaleBin();
    if (!bin) {
        console.log("skip live: radicale is not installed");
        return;
    }
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "quicknotes-radicale-"));
    fs.writeFileSync(path.join(dir, "users"), "neo:secret\nqml:secret\n");
    const port = 20000 + Math.floor(Math.random() * 20000);
    const base = "http://127.0.0.1:" + port;
    const proc = spawn(bin, ["--config", "", "--server-hosts", "127.0.0.1:" + port, "--storage-filesystem-folder", path.join(dir, "collections"), "--auth-type", "htpasswd", "--auth-htpasswd-filename", path.join(dir, "users"), "--auth-htpasswd-encryption", "plain", "--logging-level", "warning"], {
        stdio: ["ignore", "ignore", "pipe"]
    });
    let stderr = "";
    proc.stderr.on("data", d => stderr += d);
    try {
        let up = false;
        for (let i = 0; i < 50 && !up; i++) {
            await new Promise(r => setTimeout(r, 100));
            up = (await raw("PROPFIND", base + "/", {
                "Depth": "0"
            }, "")).status === 207;
        }
        if (!up)
            throw new Error("radicale did not start: " + stderr);
        const mk = (name, display, comps) => raw("MKCALENDAR", base + "/neo/" + name + "/", {
            "Content-Type": "application/xml"
        }, '<?xml version="1.0" encoding="utf-8"?><C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:set><D:prop><D:displayname>' + display + "</D:displayname><C:supported-calendar-component-set>" + comps.map(c => '<C:comp name="' + c + '"/>').join("") + "</C:supported-calendar-component-set></D:prop></D:set></C:mkcalendar>");
        // The plugin never makes a list (XMLHttpRequest cannot send
        // MKCALENDAR); the test makes two, one of them for events only.
        const made = await mk("main", "Main", ["VTODO"]);
        if (made.status !== 201)
            throw new Error("MKCALENDAR main: " + made.status + " " + made.text);
        await mk("events", "Events", ["VEVENT"]);

        const h = harness(null, httpRequest);
        h.clock = Date.now();
        h.engine.configure({
            server: base,
            user: "neo",
            password: "secret",
            listName: "main"
        });

        test("live: finds Radicale's list from the bare address and reads it empty", async () => {
            const r = await h.run("sync");
            assert.strictEqual(r.err, null, r.err && r.err.message);
            assert.strictEqual(plain(h.engine.status()).listUrl, base + "/neo/main/");
            assert.deepStrictEqual(h.tasks(), []);
        });

        let ids = [];
        test("live: tasks typed here reach the server", async () => {
            ids = [h.engine.add("milk"), h.engine.add("dentist\ncall before 5, ask for Ayşe"), h.engine.add("taxes")];
            const r = await h.run("push");
            assert.strictEqual(r.err, null, r.err && r.err.message);
            const got = await raw("GET", base + "/neo/main/" + ids[1] + ".ics");
            assert.strictEqual(got.status, 200);
            const t = ICal.readTask(got.text);
            assert.strictEqual(t.summary, "dentist");
            assert.strictEqual(t.description, "call before 5, ask for Ayşe");
            assert.ok(h.tasks().every(t => !t.pending));
        });

        test("live: a change made by another client is read back", async () => {
            const got = await raw("GET", base + "/neo/main/" + ids[0] + ".ics");
            const edited = got.text.replace("SUMMARY:milk", "SUMMARY:oat milk\r\nCATEGORIES:Shopping");
            const put = await raw("PUT", base + "/neo/main/" + ids[0] + ".ics", {
                "Content-Type": "text/calendar; charset=utf-8"
            }, edited);
            assert.ok(put.status === 201 || put.status === 204, "PUT " + put.status);
            h.clock += 1000;
            const r = await h.run("sync");
            assert.strictEqual(r.err, null);
            assert.ok(h.tasks().some(t => t.summary === "oat milk"));
        });

        test("live: marked done here, with the other client's property kept", async () => {
            h.engine.setDone(ids[0], true);
            const r = await h.run("push");
            assert.strictEqual(r.err, null, r.err && r.err.message);
            const got = await raw("GET", base + "/neo/main/" + ids[0] + ".ics");
            assert.ok(got.text.includes("STATUS:COMPLETED") && got.text.includes("CATEGORIES:Shopping"));
        });

        test("live: changed on the server after it was read -- 412, read again, marked", async () => {
            const got = await raw("GET", base + "/neo/main/" + ids[2] + ".ics");
            await raw("PUT", base + "/neo/main/" + ids[2] + ".ics", {
                "Content-Type": "text/calendar; charset=utf-8"
            }, got.text.replace("SUMMARY:taxes", "SUMMARY:taxes (by March)"));
            h.engine.setDone(ids[2], true);
            const r = await h.run("push");
            assert.strictEqual(r.err, null, r.err && r.err.message);
            const after = ICal.readTask((await raw("GET", base + "/neo/main/" + ids[2] + ".ics")).text);
            assert.strictEqual(after.summary, "taxes (by March)");
            assert.strictEqual(after.completed, true);
        });

        test("live: deleted after the undo time", async () => {
            h.engine.remove(ids[1]);
            await h.run("push");
            assert.strictEqual((await raw("GET", base + "/neo/main/" + ids[1] + ".ics")).status, 200, "still there inside the undo time");
            h.clock += Sync.UNDO_MS + 1;
            await h.run("push");
            assert.strictEqual((await raw("GET", base + "/neo/main/" + ids[1] + ".ics")).status, 404);
            h.clock += 1000;
            await h.run("sync");
            assert.deepStrictEqual(h.tasks().map(t => t.summary).sort(), ["oat milk", "taxes (by March)"]);
        });

        test("live: a wrong password is an auth error", async () => {
            const bad = harness(null, httpRequest);
            bad.engine.configure({
                server: base,
                user: "neo",
                password: "nope",
                listName: "main"
            });
            const r = await bad.run("sync");
            assert.strictEqual(r.err.kind, "auth");
        });

        test("live: an event-only calendar is not offered as a task list", async () => {
            const other = harness(null, httpRequest);
            other.engine.configure({
                server: base,
                user: "neo",
                password: "secret",
                listName: "events"
            });
            const r = await other.run("sync");
            assert.strictEqual(r.err.kind, "config");
            assert.strictEqual(r.err.message, "No task list named \"events\" (there is Main)");
        });

        test("live: the same, through Qt's XMLHttpRequest under qmltestrunner", async () => {
            const qt = qtDeclarative();
            if (!qt) {
                console.log("     (skipped: no qtdeclarative for quickshell found)");
                return;
            }
            const made = await new Promise(resolve => httpRequest({
                method: "MKCALENDAR",
                url: base + "/qml/main/",
                headers: {
                    "Authorization": Dav.basicAuth("qml", "secret"),
                    "Content-Type": "application/xml"
                },
                body: '<?xml version="1.0" encoding="utf-8"?><C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:set><D:prop><D:displayname>main</D:displayname><C:supported-calendar-component-set><C:comp name="VTODO"/></C:supported-calendar-component-set></D:prop></D:set></C:mkcalendar>'
            }, resolve));
            assert.strictEqual(made.status, 201, "MKCALENDAR /qml/main/");
            const r = runQmlTest(qt, path.join(__dirname, "qml", "XhrLiveTest.qml"), {
                "config.js": ".pragma library\nvar BASE = " + JSON.stringify(base) + ";\nvar USER = \"qml\";\n"
            });
            assert.ok(r.ok, r.out.split("\n").filter(l => /^(FAIL|PASS|Totals|QWARN|   Actual|   Expected|   Loc)|rror/.test(l)).join("\n"));
        });

        await runAll();
    } finally {
        proc.kill();
        fs.rmSync(dir, {
            recursive: true,
            force: true
        });
    }
}

(async () => {
    await runAll();
    if (process.argv.includes("--live")) {
        queue.length = 0;
        await live();
    }
    console.log(passed + " passed" + (process.exitCode ? ", some FAILED" : ""));
})();
