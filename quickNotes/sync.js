.pragma library
.import "ical.js" as ICal
.import "dav.js" as Dav

// Keeps one CalDAV task list in step with what is shown here.
//
// What the server had at the last sync is kept as it came (each task's
// calendar object and ETag, by href). What was done here and not sent yet is
// a queue of operations on top of it -- create, mark done or not done, delete
// -- and the tasks shown are always the first with the second applied. So
// nothing waits for the network: a change is in the list at once, and is sent
// in the background, again and again if need be, until the server has it.
//
// One network job runs at a time -- a push (send the queue) or a sync (send
// the queue, then read the list back) -- so a list read before a task was
// sent can never land after it and make the task vanish.
//
// The engine knows nothing of QML: requests go through env.request, so the
// shell runs it over XMLHttpRequest and the tests over node's http.
//
//   env.request({ method, url, headers, body }, done)
//       done({ status, text, etag, error }) -- status 0 when there was no answer
//   env.now()                 epoch ms
//   env.changed()             the tasks or the status changed
//   env.finished(kind, err)   a "push" or "sync" ended; err is null or
//                             { kind: "auth" | "config" | "retry", message }

// A deleted task is only deleted on the server this long after, so Ctrl+Z
// can still take it back.
var UNDO_MS = 8000;

function _emptyState() {
    return {
        version: 1,
        accountKey: "",
        listUrl: "",
        listTitle: "",
        ctag: "",
        items: {},
        pending: [],
        seq: 0,
        lastSyncMs: 0,
        lastError: "",
        lastErrorKind: ""
    };
}

function accountKey(a) {
    return String(a.server || "").trim().replace(/\/+$/, "").toLowerCase() + "|" + String(a.user || "").trim() + "|" + String(a.listName || "").trim().toLowerCase();
}

// Which task list a name means, out of [{ url, name, slug }]: the one shown
// with exactly that name, then the same ignoring case, then the one whose
// address ends in it -- Nextcloud's own name for a list made as "Main" is
// "main".
function matchList(lists, wanted) {
    const w = String(wanted || "").trim();
    const lw = w.toLowerCase();
    return lists.find(l => (l.name || "").trim() === w) || lists.find(l => (l.name || "").trim().toLowerCase() === lw) || lists.find(l => (l.slug || "").toLowerCase() === lw) || null;
}

// A response that is not what was hoped for -> { kind, message }:
//   "retry"   it may well work next time: no answer, a server error
//   "auth"    the user name or app password is wrong -- trying again only
//             walks into Nextcloud's brute-force throttling
//   "config"  the server means it: no such list, not allowed, ...
function _failure(res, what) {
    const status = res.status || 0;
    if (res.stale)
        return {
            kind: "retry",
            message: "The settings changed meanwhile"
        };
    if (status === 0)
        return {
            kind: "retry",
            message: res.error ? "No answer from the server (" + res.error + ")" : "No answer from the server"
        };
    if (status === 401)
        return {
            kind: "auth",
            message: "The server did not accept the user name and app password"
        };
    if (status === 408 || status === 429 || status >= 500)
        return {
            kind: "retry",
            message: what + ": server error " + status
        };
    const why = {
        "403": "not allowed (a list shared read-only?)",
        "404": "not found",
        "409": "the server refused it (409)",
        "412": "it changed on the server meanwhile",
        "413": "too large for the server",
        "415": "the server does not take this kind of data"
    }[String(status)];
    return {
        kind: "config",
        message: what + ": " + (why || "HTTP " + status)
    };
}

function createEngine(env) {
    const engine = {};
    let account = {
        server: "",
        user: "",
        password: "",
        listName: "main"
    };
    let state = _emptyState();
    let running = "";
    let wantSync = false;
    let wantPush = false;
    let manualSync = false;
    let inFlight = null;
    let lastRemoved = null;
    let memo = {};
    // Bumped whenever the account or the list changes: an answer to a
    // request sent before that belongs to the old one, and is not applied.
    let gen = 0;

    function changed() {
        if (env.changed)
            env.changed();
    }

    function request(method, url, headers, body, done) {
        const h = Object.assign({
            "Authorization": Dav.basicAuth(account.user, account.password)
        }, headers || {});
        const g = gen;
        env.request({
            method: method,
            url: url,
            headers: h,
            body: body === undefined ? "" : body
        }, res => done(g !== gen ? {
                status: 0,
                stale: true
            } : res || {
                status: 0
            }));
    }

    function propfind(url, depth, propList, done) {
        request("PROPFIND", url, {
            "Depth": String(depth),
            "Content-Type": "application/xml; charset=utf-8",
            "Prefer": "return=minimal"
        }, Dav.propfind(propList), res => {
            const responses = res.status === 207 ? Dav.parseMultistatus(res.text) : null;
            done(res, responses);
        });
    }

    // ------------------------------------------------------------ account

    engine.configure = function (a) {
        account = {
            server: String(a.server || "").trim(),
            user: String(a.user || "").trim(),
            password: String(a.password || ""),
            listName: String(a.listName || "").trim() || "main"
        };
        const key = accountKey(account);
        if (key === state.accountKey)
            return;
        // Another server, user or list: what is cached is the old list's.
        // Tasks typed here and not sent yet go to the new one; changes to
        // the old list's tasks have nothing left to apply to.
        state.pending = state.pending.filter(op => op.kind === "create" && op !== inFlight).map(op => {
            const o = Object.assign({}, op);
            delete o.href;
            delete o.failed;
            return o;
        });
        state.items = {};
        state.ctag = "";
        state.listUrl = "";
        state.listTitle = "";
        state.lastSyncMs = 0;
        state.lastError = "";
        state.lastErrorKind = "";
        state.accountKey = key;
        memo = {};
        gen++;
        // A job still running is talking to the old one; a fresh sync
        // follows it.
        if (running)
            wantSync = true;
        changed();
    };

    engine.configured = function () {
        return account.server !== "" && account.user !== "" && account.password !== "";
    };

    // ---------------------------------------------------------- persistence

    engine.restore = function (saved) {
        if (!saved || typeof saved !== "object" || saved.version !== 1)
            return;
        const s = _emptyState();
        for (const k in s) {
            if (saved[k] !== undefined && typeof saved[k] === typeof s[k] && Array.isArray(saved[k]) === Array.isArray(s[k]))
                s[k] = saved[k];
        }
        s.pending = s.pending.filter(op => op && op.uid && (op.kind === "create" ? !!op.ics : op.kind === "update" || op.kind === "delete"));
        state = s;
        memo = {};
        changed();
    };

    engine.snapshot = function () {
        return JSON.parse(JSON.stringify(state));
    };

    // ---------------------------------------------------------------- tasks

    function parsed(href, ics) {
        const m = memo[href];
        if (m && m.ics === ics)
            return m.task;
        const task = ics ? ICal.readTask(ics) : null;
        memo[href] = {
            ics: ics,
            task: task
        };
        return task;
    }

    // uid -> the server's copy of that task, as last read.
    function serverTasks() {
        const byUid = {};
        const live = {};
        for (const href in state.items) {
            live[href] = true;
            const t = parsed(href, state.items[href].ics);
            if (t && t.uid)
                byUid[t.uid] = Object.assign({}, t, {
                    href: href
                });
        }
        for (const href in memo) {
            if (!live[href])
                delete memo[href];
        }
        return byUid;
    }

    // Every task as it stands here: [{ uid, summary, description, completed,
    // completedAt, created, modified, parent, href, pending, failed }].
    // pending: a change to it has not reached the server yet; failed: the
    // server refused it, and why.
    engine.tasks = function () {
        const byUid = serverTasks();
        for (const uid in byUid) {
            byUid[uid].pending = false;
            byUid[uid].failed = "";
        }
        for (const op of state.pending) {
            const t = byUid[op.uid];
            if (op.kind === "create") {
                if (!t) {
                    const n = ICal.readTask(op.ics);
                    if (!n)
                        continue;
                    byUid[op.uid] = Object.assign(n, {
                        uid: op.uid,
                        href: op.href || "",
                        pending: true,
                        failed: op.failed || ""
                    });
                } else {
                    t.pending = true;
                    t.failed = op.failed || t.failed;
                }
            } else if (op.kind === "update") {
                if (!t)
                    continue;
                t.completed = op.done;
                t.completedAt = op.done ? op.at : 0;
                t.pending = true;
                t.failed = op.failed || t.failed;
            } else if (op.kind === "delete") {
                delete byUid[op.uid];
            }
        }
        return Object.keys(byUid).map(k => byUid[k]);
    };

    // ------------------------------------------------------- local changes

    engine.add = function (text) {
        if (ICal.splitText(text).summary === "")
            return "";
        const uid = ICal.newUid();
        const now = env.now();
        state.pending.push({
            id: ++state.seq,
            kind: "create",
            uid: uid,
            ics: ICal.newTodo(uid, text, now),
            at: now
        });
        changed();
        return uid;
    };

    function waitingOp(uid, kind) {
        return state.pending.findIndex(op => op.uid === uid && op.kind === kind && op !== inFlight);
    }

    engine.setDone = function (uid, done) {
        const now = env.now();
        // Not sent yet: change what will be sent.
        const ci = waitingOp(uid, "create");
        if (ci >= 0) {
            const op = state.pending[ci];
            state.pending[ci] = Object.assign({}, op, {
                ics: ICal.withCompleted(op.ics, done, now)
            });
            changed();
            return true;
        }
        const server = serverTasks()[uid] || null;
        // Already waiting to be marked: change its mind, or drop it when the
        // task is back to what the server has.
        const ui = waitingOp(uid, "update");
        if (ui >= 0) {
            if (server && server.completed === done)
                state.pending.splice(ui, 1);
            else
                state.pending[ui] = Object.assign({}, state.pending[ui], {
                    done: done,
                    at: now,
                    failed: ""
                });
            changed();
            return true;
        }
        // On its way to the server right now: marked once it is there.
        const sending = inFlight && inFlight.uid === uid && inFlight.kind === "create" ? inFlight : null;
        if (!server && !sending)
            return false;
        state.pending.push({
            id: ++state.seq,
            kind: "update",
            uid: uid,
            href: server ? server.href : sending.href,
            done: done,
            at: now
        });
        changed();
        return true;
    };

    // Gone from the list at once; gone from the server UNDO_MS later.
    engine.remove = function (uid) {
        const now = env.now();
        const server = serverTasks()[uid] || null;
        const sending = inFlight && inFlight.uid === uid ? inFlight : null;
        const ops = state.pending.filter(op => op.uid === uid && op !== inFlight);
        if (!server && !sending && !ops.some(op => op.kind === "create"))
            return false;
        state.pending = state.pending.filter(op => op.uid !== uid || op === inFlight);
        let del = null;
        if (server || sending) {
            del = {
                id: ++state.seq,
                kind: "delete",
                uid: uid,
                href: server ? server.href : sending.href,
                at: now,
                notBefore: now + UNDO_MS
            };
            state.pending.push(del);
        }
        lastRemoved = {
            uid: uid,
            ops: ops,
            deleteId: del ? del.id : 0,
            until: now + UNDO_MS
        };
        changed();
        return true;
    };

    engine.canUndo = function () {
        return !!lastRemoved && env.now() < lastRemoved.until;
    };

    // Takes back the last remove(), while its delete has not been sent.
    engine.undoRemove = function () {
        if (!engine.canUndo())
            return "";
        const r = lastRemoved;
        if (r.deleteId) {
            const i = state.pending.findIndex(op => op.id === r.deleteId);
            if (i < 0 || state.pending[i] === inFlight)
                return "";
            state.pending.splice(i, 1);
        }
        lastRemoved = null;
        state.pending = state.pending.concat(r.ops);
        changed();
        return r.uid;
    };

    // ------------------------------------------------------------ discovery

    function setList(url, title) {
        if (url !== state.listUrl) {
            // Addresses worked out for the old list mean nothing now.
            state.pending = state.pending.filter(op => op.kind === "create" || (op.href && op.href.indexOf(url) === 0)).map(op => {
                if (op.kind !== "create" || op === inFlight)
                    return op;
                const o = Object.assign({}, op);
                delete o.href;
                return o;
            });
            state.items = {};
            state.ctag = "";
            memo = {};
            gen++;
        }
        state.listUrl = url;
        state.listTitle = title;
        changed();
    }

    function listCalendars(homeUrl, done) {
        propfind(homeUrl, 1, [[Dav.DAV, "resourcetype"], [Dav.DAV, "displayname"], [Dav.CALDAV, "supported-calendar-component-set"]], (res, responses) => {
            if (!responses)
                return done(_failure(res, "Reading the task lists"));
            const lists = responses.filter(r => Dav.isCalendar(r) && Dav.supportsTodo(r)).map(r => ({
                        url: Dav.withSlash(Dav.resolve(homeUrl, r.href)),
                        name: Dav.propText(r, Dav.DAV, "displayname"),
                        slug: Dav.lastSegment(r.href)
                    }));
            const pick = matchList(lists, account.listName);
            if (!pick) {
                const names = lists.map(l => l.name || l.slug).filter(Boolean);
                return done({
                    kind: "config",
                    message: "No task list named \"" + account.listName + "\"" + (names.length > 0 ? " (there is " + names.join(", ") + ")" : " (there are no task lists)")
                });
            }
            setList(pick.url, pick.name || pick.slug);
            done(null);
        });
    }

    function findHome(principalUrl, done) {
        propfind(principalUrl, 0, [[Dav.CALDAV, "calendar-home-set"]], (res, responses) => {
            if (!responses)
                return done(_failure(res, "Reading the account"));
            const home = responses.length > 0 ? Dav.propHref(responses[0], Dav.CALDAV, "calendar-home-set") : "";
            if (!home)
                return done({
                    kind: "config",
                    message: "The server has no calendars for this account"
                });
            listCalendars(Dav.withSlash(Dav.resolve(principalUrl, home)), done);
        });
    }

    function discover(done) {
        const starts = Dav.startUrls(account.server);
        const props = [[Dav.DAV, "current-user-principal"], [Dav.CALDAV, "calendar-home-set"], [Dav.DAV, "resourcetype"], [Dav.DAV, "displayname"], [Dav.CALDAV, "supported-calendar-component-set"]];
        let lastRes = {
            status: 0
        };
        const attempt = i => {
            if (i >= starts.length)
                return done(lastRes.status === 0 ? _failure(lastRes, "Connecting") : {
                    kind: "config",
                    message: "No CalDAV service at " + account.server + " (HTTP " + lastRes.status + ")"
                });
            propfind(starts[i], 0, props, (res, responses) => {
                if (res.status === 401 || res.status === 0)
                    return done(_failure(res, "Connecting"));
                const r = responses && responses.length > 0 ? responses[0] : null;
                if (!r) {
                    lastRes = res;
                    return attempt(i + 1);
                }
                // The address is a task list's own link.
                if (Dav.isCalendar(r) && Dav.supportsTodo(r)) {
                    setList(Dav.withSlash(Dav.resolve(starts[i], r.href || starts[i])), Dav.propText(r, Dav.DAV, "displayname") || Dav.lastSegment(r.href || starts[i]));
                    return done(null);
                }
                const home = Dav.propHref(r, Dav.CALDAV, "calendar-home-set");
                if (home)
                    return listCalendars(Dav.withSlash(Dav.resolve(starts[i], home)), done);
                const principal = Dav.propHref(r, Dav.DAV, "current-user-principal");
                if (principal)
                    return findHome(Dav.resolve(starts[i], principal), done);
                lastRes = res;
                attempt(i + 1);
            });
        };
        attempt(0);
    }

    function ensureList(done) {
        if (state.listUrl)
            return done(null);
        discover(done);
    }

    // ---------------------------------------------------------------- push

    function dropOp(op) {
        state.pending = state.pending.filter(o => o !== op);
    }

    function hrefFor(uid) {
        return state.listUrl + encodeURIComponent(uid) + ".ics";
    }

    function sendCreate(op, done) {
        op.href = op.href || hrefFor(op.uid);
        request("PUT", op.href, {
            "Content-Type": "text/calendar; charset=utf-8",
            "If-None-Match": "*"
        }, op.ics, res => {
            if (res.status >= 200 && res.status < 300) {
                state.items[op.href] = {
                    etag: res.etag || "",
                    ics: op.ics
                };
                dropOp(op);
                return done(null);
            }
            // It is there already: an earlier try got through and only its
            // answer was lost. It may have been marked here since, which the
            // server has not seen, so that much goes again as an update, in
            // this one's place in the queue; and the list is read afresh.
            if (res.status === 412) {
                const local = ICal.readTask(op.ics) || {};
                state.pending.splice(state.pending.indexOf(op), 1, {
                    id: ++state.seq,
                    kind: "update",
                    uid: op.uid,
                    href: op.href,
                    done: !!local.completed,
                    at: local.completedAt || env.now()
                });
                state.ctag = "";
                return done(null);
            }
            done(_failure(res, "Adding a task"));
        });
    }

    // GET, then PUT with If-Match on that ETag; a 412 means someone changed
    // it in between, so once more from a fresh GET. A server that sends no
    // ETag at all gets a plain PUT. A proxy that compresses GET answers
    // (nginx in front of Nextcloud, often) hands out weak W/"..." ETags,
    // which If-Match never matches; the server's own is the quoted part.
    function sendUpdate(op, done, retried) {
        const put = item => {
            const ics = ICal.withCompleted(item.ics, op.done, op.at);
            const headers = {
                "Content-Type": "text/calendar; charset=utf-8"
            };
            if (item.etag)
                headers["If-Match"] = item.etag.replace(/^W\//, "");
            request("PUT", op.href, headers, ics, res => {
                if (res.status >= 200 && res.status < 300) {
                    state.items[op.href] = {
                        etag: res.etag || "",
                        ics: ics
                    };
                    dropOp(op);
                    return done(null);
                }
                if (res.status === 404) {
                    delete state.items[op.href];
                    dropOp(op);
                    return done(null);
                }
                if (res.status === 412 && !retried) {
                    delete state.items[op.href];
                    return sendUpdate(op, done, true);
                }
                done(_failure(res, "Marking a task"));
            });
        };
        const cached = state.items[op.href];
        if (cached && cached.etag && cached.ics)
            return put(cached);
        request("GET", op.href, {}, "", res => {
            if (res.status === 404) {
                delete state.items[op.href];
                dropOp(op);
                return done(null);
            }
            if (res.status !== 200 || !/BEGIN:VTODO/i.test(res.text || ""))
                return done(_failure(res, "Reading a task"));
            state.items[op.href] = {
                etag: res.etag || "",
                ics: res.text
            };
            put(state.items[op.href]);
        });
    }

    function sendDelete(op, done) {
        request("DELETE", op.href, {}, "", res => {
            if (res.status >= 200 && res.status < 300 || res.status === 404) {
                delete state.items[op.href];
                dropOp(op);
                return done(null);
            }
            done(_failure(res, "Deleting a task"));
        });
    }

    // The next operation to send: in order, except that a delete still
    // inside its undo time, or one the server refused for good, holds back
    // only the later operations on that same task.
    function nextOp() {
        const now = env.now();
        const held = {};
        for (const op of state.pending) {
            if (held[op.uid])
                continue;
            if (op.failed || (op.notBefore && op.notBefore > now)) {
                held[op.uid] = true;
                continue;
            }
            return op;
        }
        return null;
    }

    // Sends until the queue is empty or something fails. A refusal that will
    // not change by trying again (a read-only list, say) marks that
    // operation failed and goes on with the rest; anything else -- offline,
    // a server error, a wrong password -- stops here and keeps the queue.
    function flush(done) {
        const op = nextOp();
        if (!op)
            return done(null);
        const send = op.kind === "create" ? sendCreate : op.kind === "update" ? sendUpdate : sendDelete;
        inFlight = op;
        send(op, err => {
            inFlight = null;
            if (err && err.kind === "config") {
                op.failed = err.message;
                err = null;
            }
            changed();
            if (err)
                return done(err);
            flush(done);
        });
    }

    // ---------------------------------------------------------------- pull

    // The list's ctag (or sync-token) changes whenever anything in it does:
    // when it has not, nothing is read. When it has, everything is, in one
    // PROPFIND -- Nextcloud answers calendar-data there -- with a GET for
    // each changed task from a server that does not.
    function pull(done) {
        propfind(state.listUrl, 0, [[Dav.CS, "getctag"], [Dav.DAV, "sync-token"], [Dav.DAV, "displayname"]], (res, responses) => {
            if (res.status === 404) {
                state.listUrl = "";
                return done({
                    kind: "retry",
                    message: "The task list is gone from the server"
                });
            }
            if (!responses || responses.length === 0)
                return done(_failure(res, "Reading the task list"));
            const r = responses.find(x => Dav.samePath(Dav.resolve(state.listUrl, x.href), state.listUrl)) || responses[0];
            const ctag = Dav.propText(r, Dav.CS, "getctag") || Dav.propText(r, Dav.DAV, "sync-token");
            const title = Dav.propText(r, Dav.DAV, "displayname");
            if (title)
                state.listTitle = title;
            if (ctag && ctag === state.ctag)
                return done(null);
            readAll(ctag, done);
        });
    }

    function readAll(ctag, done) {
        const listUrl = state.listUrl;
        propfind(listUrl, 1, [[Dav.DAV, "getetag"], [Dav.CALDAV, "calendar-data"]], (res, responses) => {
            if (!responses)
                return done(_failure(res, "Reading the tasks"));
            const items = {};
            const toGet = [];
            for (const r of responses) {
                const href = Dav.resolve(listUrl, r.href);
                if (Dav.samePath(href, listUrl))
                    continue;
                const etag = Dav.propText(r, Dav.DAV, "getetag");
                const data = Dav.propRaw(r, Dav.CALDAV, "calendar-data");
                const old = state.items[href];
                if (data)
                    items[href] = {
                        etag: etag,
                        ics: /BEGIN:VTODO/i.test(data) ? data : ""
                    };
                else if (old && etag && old.etag === etag)
                    items[href] = old;
                else
                    toGet.push({
                        href: href,
                        etag: etag
                    });
            }
            const next = i => {
                if (i >= toGet.length) {
                    state.items = items;
                    state.ctag = ctag;
                    return done(null);
                }
                request("GET", toGet[i].href, {}, "", g => {
                    if (g.status === 200)
                        items[toGet[i].href] = {
                            etag: g.etag || toGet[i].etag,
                            ics: /BEGIN:VTODO/i.test(g.text || "") ? g.text : ""
                        };
                    else if (g.status !== 404)
                        return done(_failure(g, "Reading a task"));
                    next(i + 1);
                });
            };
            next(0);
        });
    }

    // ----------------------------------------------------------------- jobs

    function finish(kind, err) {
        running = "";
        if (err) {
            state.lastError = err.message;
            state.lastErrorKind = err.kind;
        } else {
            state.lastError = "";
            state.lastErrorKind = "";
            if (kind === "sync")
                state.lastSyncMs = env.now();
        }
        changed();
        if (env.finished)
            env.finished(kind, err);
        pump();
    }

    function pump() {
        if (running)
            return;
        if (!wantSync && !wantPush)
            return;
        const kind = wantSync ? "sync" : "push";
        const manual = manualSync;
        wantSync = false;
        wantPush = false;
        manualSync = false;
        if (!engine.configured()) {
            const err = {
                kind: "config",
                message: "Not set up yet"
            };
            if (env.finished)
                env.finished(kind, err);
            return;
        }
        running = kind;
        // Asked for by hand: try again what the server refused before.
        if (manual)
            state.pending.forEach(op => delete op.failed);
        changed();
        ensureList(err => {
            if (err)
                return finish(kind, err);
            flush(err => {
                if (err || kind === "push")
                    return finish(kind, err);
                pull(err => finish(kind, err));
            });
        });
    }

    // Send what is waiting, then read the list back.
    engine.sync = function (manual) {
        wantSync = true;
        manualSync = manualSync || !!manual;
        pump();
    };

    // Only send what is waiting.
    engine.push = function () {
        wantPush = true;
        pump();
    };

    // ---------------------------------------------------------------- status

    engine.status = function () {
        const now = env.now();
        let nextDue = 0;
        for (const op of state.pending) {
            if (op.notBefore && op.notBefore > now && (nextDue === 0 || op.notBefore < nextDue))
                nextDue = op.notBefore;
        }
        return {
            running: running,
            listUrl: state.listUrl,
            listTitle: state.listTitle,
            lastSyncMs: state.lastSyncMs,
            lastError: state.lastError,
            lastErrorKind: state.lastErrorKind,
            waiting: state.pending.filter(op => !op.failed).length,
            failed: state.pending.filter(op => !!op.failed).length,
            nextDueMs: nextDue
        };
    };

    return engine;
}
