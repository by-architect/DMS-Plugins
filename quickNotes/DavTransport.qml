import QtQuick

// The sync engine's env.request (see sync.js) over XMLHttpRequest: in the
// shell's own process, nothing to install, and the password in a header
// rather than on a command line where `ps` would show it to everyone.
//
// Qt's XMLHttpRequest sends GET, PUT, DELETE and PROPFIND -- all CalDAV
// needs here -- and follows redirects with the method kept, so
// /.well-known/caldav works. It has no timeout of its own, hence the timer.
// Plain QtQuick only, so the tests run it under qmltestrunner.
Item {
    id: root

    property int timeoutMs: 30000

    property bool _alive: true
    property var _requests: []

    Component {
        id: timeoutComponent

        Timer {
            repeat: false
        }
    }

    // req: { method, url, headers, body }; done({ status, text, etag, error })
    // is called exactly once -- status 0 when no answer came.
    function request(req, done) {
        const xhr = new XMLHttpRequest();
        const timer = timeoutComponent.createObject(root, {
            interval: root.timeoutMs
        });
        let finished = false;
        const finish = res => {
            if (finished)
                return;
            finished = true;
            timer.stop();
            timer.destroy();
            const i = root._requests.indexOf(xhr);
            if (i >= 0)
                root._requests.splice(i, 1);
            if (root._alive)
                done(res);
        };
        root._requests.push(xhr);
        timer.triggered.connect(() => {
            finish({
                status: 0,
                error: "timed out"
            });
            xhr.abort();
        });
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            let etag = "";
            try {
                etag = xhr.getResponseHeader("ETag") || "";
            } catch (e) {}
            finish({
                status: xhr.status,
                text: xhr.responseText || "",
                etag: etag,
                error: xhr.status === 0 ? xhr.statusText || "" : ""
            });
        };
        try {
            xhr.open(req.method, req.url);
            for (const name in req.headers)
                xhr.setRequestHeader(name, req.headers[name]);
            xhr.send(req.body || "");
            timer.start();
        } catch (e) {
            finish({
                status: 0,
                error: String(e && e.message ? e.message : e)
            });
        }
    }

    // Nothing answered after this goes anywhere.
    function stop() {
        _alive = false;
        for (const xhr of _requests.slice())
            xhr.abort();
    }

    Component.onDestruction: stop()
}
