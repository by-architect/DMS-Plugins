import QtQuick
import "sync.js" as Sync
import "ical.js" as ICal

// What QuickNotesCard needs of QuickNotesService, over the real sync engine
// with no network: everything done here stays in its queue. seed() puts back
// four tasks as if just read from the server -- alpha, beta and gamma (with
// notes), oldest first, and "ancient", done a month ago.
Item {
    id: root

    property var tasks: []
    property var status: ({
            running: "",
            listUrl: "",
            listTitle: "main",
            lastSyncMs: 0,
            lastError: "",
            lastErrorKind: "",
            waiting: 0,
            failed: 0,
            nextDueMs: 0
        })
    property bool configured: true
    property int keepDoneHours: 24
    readonly property string listTitle: "main"
    readonly property bool syncing: false
    property int syncs: 0
    property var engine: null

    function refresh() {
        tasks = engine.tasks();
        status = engine.status();
    }

    function seed() {
        syncs = 0;
        keepDoneHours = 24;
        const now = Date.now();
        const items = {};
        const put = (uid, text, minutesAgo, doneMsAgo) => {
            let ics = ICal.newTodo(uid, text, now - minutesAgo * 60000);
            if (doneMsAgo)
                ics = ICal.withCompleted(ics, true, now - doneMsAgo);
            items["https://example.invalid/main/" + uid + ".ics"] = {
                etag: '"1"',
                ics: ics
            };
        };
        put("a", "alpha", 30);
        put("b", "beta", 20);
        put("g", "gamma\ng notes", 10);
        put("x", "ancient", 60 * 24 * 40, 30 * 86400000);
        engine = Sync.createEngine({
            request: (req, done) => done({
                    status: 0,
                    error: "offline"
                }),
            now: () => Date.now(),
            changed: () => root.refresh(),
            finished: () => {}
        });
        engine.restore({
            version: 1,
            accountKey: "",
            listUrl: "https://example.invalid/main/",
            listTitle: "main",
            ctag: "1",
            items: items,
            pending: [],
            seq: 0,
            lastSyncMs: now,
            lastError: "",
            lastErrorKind: ""
        });
        refresh();
    }

    function add(text) {
        return engine.add(text);
    }

    function setDone(uid, done) {
        engine.setDone(uid, done);
    }

    function remove(uid) {
        return engine.remove(uid);
    }

    function canUndo() {
        return engine.canUndo();
    }

    function undoRemove() {
        return engine.undoRemove();
    }

    function syncNow() {
        syncs++;
    }
}
