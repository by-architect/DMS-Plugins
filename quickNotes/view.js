.pragma library

// What the window shows, worked out from the engine's task list: which
// tasks, in what order and how far in, what a search finds, and the short
// words for when something happened.

// For matching: case, accents and the Turkish dotted/dotless i do not
// matter, so "istanbul" finds "İstanbul" and "cay" finds "çay".
function fold(s) {
    let t = String(s || "");
    try {
        t = t.normalize("NFD");
    } catch (e) {}
    return t.replace(/[̀-ͯ]/g, "").toLowerCase().replace(/ı/g, "i");
}

// Every word of the query somewhere in the task's title or notes.
function matches(task, query) {
    const words = fold(query).split(/\s+/).filter(Boolean);
    if (words.length === 0)
        return true;
    const hay = fold(task.summary + "\n" + task.description);
    return words.every(w => hay.indexOf(w) >= 0);
}

// Open tasks always; done ones for keepDoneHours after they were done (-1:
// always, 0: never), and any marked in this sitting -- `keep` holds their
// uids -- so one does not vanish from under the key that just marked it.
function isVisible(task, nowMs, keepDoneHours, keep) {
    if (!task.completed)
        return true;
    if (keep && keep[task.uid])
        return true;
    if (keepDoneHours < 0)
        return true;
    if (keepDoneHours === 0)
        return false;
    const at = task.completedAt || task.modified || 0;
    return at > 0 && nowMs - at < keepDoneHours * 3600000;
}

function _compare(a, b) {
    return (a.created || 0) - (b.created || 0) || String(a.summary).localeCompare(String(b.summary)) || (a.uid < b.uid ? -1 : a.uid > b.uid ? 1 : 0);
}

// Reading order, top to bottom: oldest first, so the newest sits right
// above the field it was typed into. A subtask follows its parent, a step
// further in (depth, at most 3); one whose parent is not shown stands alone.
function order(tasks) {
    const shown = {};
    for (const t of tasks)
        shown[t.uid] = true;
    const kids = {};
    const roots = [];
    for (const t of tasks) {
        if (t.parent && t.parent !== t.uid && shown[t.parent])
            (kids[t.parent] = kids[t.parent] || []).push(t);
        else
            roots.push(t);
    }
    const out = [];
    const seen = {};
    const walk = (t, depth) => {
        if (seen[t.uid])
            return;
        seen[t.uid] = true;
        out.push(Object.assign({}, t, {
            depth: Math.min(depth, 3)
        }));
        (kids[t.uid] || []).sort(_compare).forEach(k => walk(k, depth + 1));
    };
    roots.sort(_compare).forEach(t => walk(t, 0));
    // Parents that are each other's children reach no root at all.
    tasks.filter(t => !seen[t.uid]).sort(_compare).forEach(t => walk(t, 0));
    return out;
}

// The rows for a bottom-to-top list: index 0 is the newest, the one right
// above the field. `query` is null when not searching; a search looks
// through every task, done ones from long ago too.
function rows(tasks, opts) {
    const list = tasks || [];
    const shown = opts.query !== null && opts.query !== undefined ? list.filter(t => matches(t, opts.query)) : list.filter(t => isVisible(t, opts.nowMs, opts.keepDoneHours, opts.keep));
    return order(shown).reverse();
}

// "now", "5m", "3h", "2d", "3w", then the date.
function age(ms, nowMs) {
    if (!ms)
        return "";
    const s = Math.max(0, (nowMs - ms) / 1000);
    if (s < 60)
        return "now";
    if (s < 3600)
        return Math.floor(s / 60) + "m";
    if (s < 86400)
        return Math.floor(s / 3600) + "h";
    if (s < 86400 * 7)
        return Math.floor(s / 86400) + "d";
    if (s < 86400 * 7 * 5)
        return Math.floor(s / (86400 * 7)) + "w";
    const d = new Date(ms);
    const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return d.getDate() + " " + months[d.getMonth()] + (d.getFullYear() !== new Date(nowMs).getFullYear() ? " " + d.getFullYear() : "");
}

function _ago(ms, nowMs) {
    const s = Math.max(0, (nowMs - ms) / 1000);
    if (s < 60)
        return "just now";
    if (s < 3600)
        return Math.floor(s / 60) + " min ago";
    if (s < 86400)
        return Math.floor(s / 3600) + " h ago";
    return Math.floor(s / 86400) + " d ago";
}

// One line on how the list stands with the server, and whether it is bad
// news: { text, error }.
function syncLine(status, configured, nowMs) {
    const waiting = status.waiting > 0 ? status.waiting + (status.waiting === 1 ? " change" : " changes") + " waiting to be sent" : "";
    const failed = status.failed > 0 ? status.failed + " refused by the server" : "";
    if (!configured)
        return {
            text: "Kept here only — set up Nextcloud under Settings → Plugins → Quick Notes" + (waiting ? " · " + waiting : ""),
            error: false
        };
    if (status.running)
        return {
            text: "Syncing…",
            error: false
        };
    if (status.lastError)
        return {
            text: status.lastError + (waiting ? " · " + waiting : ""),
            error: true
        };
    const parts = [];
    if (waiting)
        parts.push(waiting);
    if (failed)
        parts.push(failed);
    if (parts.length === 0)
        parts.push(status.lastSyncMs ? "Synced " + _ago(status.lastSyncMs, nowMs) : "Not synced yet");
    return {
        text: parts.join(" · "),
        error: failed !== ""
    };
}
