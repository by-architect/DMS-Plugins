import QtQuick
import QtTest
import "sync.js" as Sync
import "config.js" as Config

// The sync engine over DavTransport.qml -- Qt's own XMLHttpRequest, the way
// the shell runs it -- against a real CalDAV server. Not run on its own: `node
// tests/quicknotes.test.js --live` starts Radicale, copies this next to the
// plugin's .js files and DavTransport.qml with a config.js naming the server,
// and runs it under qmltestrunner from the Qt quickshell is built on.
TestCase {
    id: tc

    name: "XhrAgainstCalDAV"

    property var engine: null
    property var finished: null
    property real skew: 0

    DavTransport {
        id: transport

        timeoutMs: 10000
    }

    function makeEngine(password) {
        return Sync.createEngine({
            request: (req, done) => transport.request(req, done),
            now: () => Date.now() + tc.skew,
            changed: () => {},
            finished: (kind, err) => tc.finished = {
                kind: kind,
                err: err
            }
        });
    }

    function run(e, kind) {
        tc.finished = null;
        if (kind === "push")
            e.push();
        else
            e.sync(false);
        tryVerify(() => tc.finished !== null, 20000, kind + " ended");
        return tc.finished;
    }

    function initTestCase() {
        engine = makeEngine();
        engine.configure({
            server: Config.BASE,
            user: Config.USER,
            password: "secret",
            listName: "main"
        });
    }

    // From the bare address: remote.php/dav is not there, /.well-known/caldav
    // redirects, and the principal and calendar home lead to the list.
    function test_1_finds_the_list() {
        const r = run(engine, "sync");
        compare(r.err, null);
        compare(engine.status().listUrl, Config.BASE + "/" + Config.USER + "/main/");
        compare(engine.tasks().length, 0);
    }

    function test_2_adds_and_reads_back() {
        const uid = engine.add("from QML\nwith notes, ü and ş");
        verify(uid !== "");
        let r = run(engine, "push");
        compare(r.err, null);
        // A second engine reading the same list proves the server has it.
        const other = makeEngine();
        other.configure({
            server: Config.BASE,
            user: Config.USER,
            password: "secret",
            listName: "main"
        });
        r = run(other, "sync");
        compare(r.err, null);
        const t = other.tasks().find(x => x.uid === uid);
        verify(!!t, "the other engine sees it");
        compare(t.summary, "from QML");
        compare(t.description, "with notes, ü and ş");
        compare(t.pending, false);
    }

    function test_3_marks_done_on_the_etag() {
        const t = engine.tasks()[0];
        verify(engine.setDone(t.uid, true));
        let r = run(engine, "push");
        compare(r.err, null);
        r = run(engine, "sync");
        compare(r.err, null);
        compare(engine.tasks()[0].completed, true);
        compare(engine.status().waiting, 0);
    }

    function test_4_deletes_after_the_undo_time() {
        const t = engine.tasks()[0];
        verify(engine.remove(t.uid));
        tc.skew += Sync.UNDO_MS + 1;
        let r = run(engine, "push");
        compare(r.err, null);
        r = run(engine, "sync");
        compare(r.err, null);
        compare(engine.tasks().length, 0);
    }

    function test_5_wrong_password() {
        const bad = makeEngine();
        bad.configure({
            server: Config.BASE,
            user: Config.USER,
            password: "wrong",
            listName: "main"
        });
        const r = run(bad, "sync");
        compare(r.err.kind, "auth");
    }

    function test_6_no_server() {
        const gone = makeEngine();
        gone.configure({
            server: "http://127.0.0.1:9",
            user: Config.USER,
            password: "secret",
            listName: "main"
        });
        const r = run(gone, "sync");
        compare(r.err.kind, "retry");
    }
}
