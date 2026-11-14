.pragma library

// Just enough iCalendar (RFC 5545) for to-dos: read a VTODO out of a calendar
// object, write a new one, and mark one done or not done without disturbing
// anything else in the file -- alarms, categories, a due date or properties
// some other client invented all go back to the server exactly as they came.
//
// A task's text is split the way Nextcloud Tasks shows it: the first line is
// the SUMMARY (its title), every line after that the DESCRIPTION (its notes).

// --------------------------------------------------------------- content lines

// Lines end in CRLF (a lax server may send bare LF); a line that starts with a
// space or a tab continues the one before it.
function unfold(text) {
    return String(text || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n[ \t]/g, "").split("\n").filter(l => l.length > 0);
}

// Splits on `sep` outside double quotes: a parameter value may be a quoted
// string holding ":" or ";".
function _splitUnquoted(s, sep) {
    const parts = [];
    let cur = "";
    let quoted = false;
    for (let i = 0; i < s.length; i++) {
        const c = s[i];
        if (c === '"')
            quoted = !quoted;
        if (c === sep && !quoted) {
            parts.push(cur);
            cur = "";
        } else {
            cur += c;
        }
    }
    parts.push(cur);
    return parts;
}

// "DESCRIPTION;LANGUAGE=en:Some text" -> { name, params, value }
function parseLine(line) {
    let i = 0;
    let quoted = false;
    for (; i < line.length; i++) {
        const c = line[i];
        if (c === '"')
            quoted = !quoted;
        else if (c === ":" && !quoted)
            break;
    }
    const head = _splitUnquoted(line.slice(0, i), ";");
    const params = {};
    for (let k = 1; k < head.length; k++) {
        const eq = head[k].indexOf("=");
        if (eq > 0)
            params[head[k].slice(0, eq).toUpperCase()] = head[k].slice(eq + 1).replace(/^"(.*)"$/, "$1");
    }
    return {
        name: head[0].toUpperCase(),
        params: params,
        value: line.slice(i + 1)
    };
}

function _lineName(line) {
    const m = /^[^;:]*/.exec(line);
    return m[0].toUpperCase();
}

// A line may be at most 75 octets; longer ones go on over continuation lines
// that start with a space. Never inside a character: counted in UTF-8 bytes,
// cut between code points.
function foldLine(line) {
    const out = [];
    let cur = "";
    let bytes = 0;
    for (const ch of line) {
        const cp = ch.codePointAt(0);
        const len = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
        if (bytes + len > 75) {
            out.push(cur);
            cur = " ";
            bytes = 1;
        }
        cur += ch;
        bytes += len;
    }
    out.push(cur);
    return out.join("\r\n");
}

// -------------------------------------------------------------------- values

function escapeText(s) {
    return String(s).replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r\n|\r|\n/g, "\\n");
}

function unescapeText(s) {
    return String(s).replace(/\\([\\;,nN])/g, (m, c) => c === "n" || c === "N" ? "\n" : c);
}

// 20261114T093000Z (UTC), 20261114T123000 (floating, read as local time) or
// 20261114 (a date) -> epoch ms; 0 for anything else.
function parseDate(v) {
    const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(String(v || "").trim());
    if (!m)
        return 0;
    const y = +m[1], mo = +m[2] - 1, d = +m[3], h = +(m[4] || 0), mi = +(m[5] || 0), s = +(m[6] || 0);
    return m[7] ? Date.UTC(y, mo, d, h, mi, s) : new Date(y, mo, d, h, mi, s).getTime();
}

function formatUtc(ms) {
    const d = new Date(ms);
    const p = (n, w) => String(n).padStart(w || 2, "0");
    return p(d.getUTCFullYear(), 4) + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) + "T" + p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds()) + "Z";
}

// ---------------------------------------------------------------- components

// -> { name: "VCALENDAR", props: [line, ...], children: [component, ...] },
// with every property kept as its whole unfolded line so it can be written
// back untouched; null when there is no component at all.
function parse(text) {
    const root = {
        name: "",
        props: [],
        children: []
    };
    const stack = [root];
    for (const line of unfold(text)) {
        const name = _lineName(line);
        if (name === "BEGIN") {
            const comp = {
                name: line.slice(line.indexOf(":") + 1).trim().toUpperCase(),
                props: [],
                children: []
            };
            stack[stack.length - 1].children.push(comp);
            stack.push(comp);
        } else if (name === "END") {
            if (stack.length > 1)
                stack.pop();
        } else {
            stack[stack.length - 1].props.push(line);
        }
    }
    return root.children[0] || null;
}

function serialize(comp) {
    const out = [];
    const walk = c => {
        out.push("BEGIN:" + c.name);
        for (const p of c.props)
            out.push(foldLine(p));
        for (const child of c.children)
            walk(child);
        out.push("END:" + c.name);
    };
    walk(comp);
    return out.join("\r\n") + "\r\n";
}

function props(comp, name) {
    return comp.props.filter(l => _lineName(l) === name).map(parseLine);
}

function prop(comp, name) {
    const line = comp.props.find(l => _lineName(l) === name);
    return line === undefined ? null : parseLine(line);
}

// Replaces every NAME line (whatever its parameters) with one plain
// NAME:value, where the first one was, or adds it at the end.
function setProp(comp, name, value) {
    const line = name + ":" + value;
    const at = comp.props.findIndex(l => _lineName(l) === name);
    const rest = comp.props.filter(l => _lineName(l) !== name);
    if (at < 0)
        rest.push(line);
    else
        rest.splice(Math.min(at, rest.length), 0, line);
    comp.props = rest;
}

function removeProp(comp, name) {
    comp.props = comp.props.filter(l => _lineName(l) !== name);
}

// The task itself, not an override of one occurrence of a repeating one.
function findTodo(cal) {
    if (!cal)
        return null;
    const todos = cal.children.filter(c => c.name === "VTODO");
    return todos.find(t => !prop(t, "RECURRENCE-ID")) || todos[0] || null;
}

// ---------------------------------------------------------------------- tasks

// Calendar object text -> { uid, summary, description, completed,
// completedAt, created, modified, parent }, or null when it holds no to-do.
//
// Done means a COMPLETED date or STATUS:COMPLETED -- Nextcloud Tasks looks at
// the first, DAVx5 and most phone apps at the second. A cancelled task counts
// as done too: it is not something left to do.
function readTask(text) {
    const todo = findTodo(parse(text));
    if (!todo)
        return null;
    const value = name => {
        const p = prop(todo, name);
        return p ? p.value : "";
    };
    const status = value("STATUS").toUpperCase();
    const completedAt = parseDate(value("COMPLETED"));
    const parent = props(todo, "RELATED-TO").find(p => !p.params.RELTYPE || p.params.RELTYPE.toUpperCase() === "PARENT");
    return {
        uid: value("UID").trim(),
        summary: unescapeText(value("SUMMARY")),
        description: unescapeText(value("DESCRIPTION")),
        completed: completedAt > 0 || status === "COMPLETED" || status === "CANCELLED",
        completedAt: completedAt,
        created: parseDate(value("CREATED")) || parseDate(value("DTSTAMP")),
        modified: parseDate(value("LAST-MODIFIED")) || parseDate(value("DTSTAMP")),
        parent: parent ? parent.value.trim() : ""
    };
}

// What was typed -> { summary, description }: the first line that has
// anything on it, and the lines after it with the blank ones around them
// dropped. A Shift+Enter line break may arrive as U+2028/U+2029.
function splitText(text) {
    const lines = String(text || "").replace(/\r\n?/g, "\n").replace(/[\u2028\u2029]/g, "\n").split("\n").map(l => l.replace(/\s+$/, ""));
    while (lines.length > 0 && lines[0].trim() === "")
        lines.shift();
    while (lines.length > 0 && lines[lines.length - 1].trim() === "")
        lines.pop();
    if (lines.length === 0)
        return {
            summary: "",
            description: ""
        };
    return {
        summary: lines[0].trim(),
        description: lines.slice(1).join("\n").replace(/^\n+/, "")
    };
}

function newTodo(uid, text, nowMs, prodId) {
    const t = splitText(text);
    const stamp = formatUtc(nowMs);
    const todo = ["UID:" + uid, "CREATED:" + stamp, "LAST-MODIFIED:" + stamp, "DTSTAMP:" + stamp, "SUMMARY:" + escapeText(t.summary)];
    if (t.description)
        todo.push("DESCRIPTION:" + escapeText(t.description));
    todo.push("STATUS:NEEDS-ACTION");
    return serialize({
        name: "VCALENDAR",
        props: ["VERSION:2.0", "PRODID:" + (prodId || "-//DankMaterialShell//Quick Notes//EN"), "CALSCALE:GREGORIAN"],
        children: [
            {
                name: "VTODO",
                props: todo,
                children: []
            }
        ]
    });
}

// The same calendar object with its task marked done (STATUS, COMPLETED and
// PERCENT-COMPLETE, as Nextcloud Tasks writes them) or open again, and
// everything else as it was. Text that holds no to-do comes back unchanged.
function withCompleted(text, done, nowMs) {
    const cal = parse(text);
    const todo = findTodo(cal);
    if (!todo)
        return text;
    const stamp = formatUtc(nowMs);
    if (done) {
        setProp(todo, "STATUS", "COMPLETED");
        setProp(todo, "PERCENT-COMPLETE", "100");
        setProp(todo, "COMPLETED", stamp);
    } else {
        setProp(todo, "STATUS", "NEEDS-ACTION");
        removeProp(todo, "PERCENT-COMPLETE");
        removeProp(todo, "COMPLETED");
    }
    setProp(todo, "LAST-MODIFIED", stamp);
    setProp(todo, "DTSTAMP", stamp);
    return serialize(cal);
}

// A random v4 UUID, which is what Nextcloud Tasks and DAVx5 use for UIDs.
function newUid() {
    const hex = "0123456789abcdef";
    let s = "";
    for (let i = 0; i < 36; i++) {
        if (i === 8 || i === 13 || i === 18 || i === 23)
            s += "-";
        else if (i === 14)
            s += "4";
        else if (i === 19)
            s += hex[8 + Math.floor(Math.random() * 4)];
        else
            s += hex[Math.floor(Math.random() * 16)];
    }
    return s;
}
