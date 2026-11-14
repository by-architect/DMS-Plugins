.pragma library

// The WebDAV side of CalDAV: the PROPFIND bodies this plugin sends, reading
// the multistatus XML that comes back, and the URL arithmetic between the
// two. A small XML reader of its own rather than XMLHttpRequest's
// responseXML, whose DOM in QML has neither localName nor
// getElementsByTagName -- and this way it runs under node for the tests.

var DAV = "DAV:";
var CALDAV = "urn:ietf:params:xml:ns:caldav";
var CS = "http://calendarserver.org/ns/";

// ------------------------------------------------------------------------ XML

function decodeEntities(s) {
    return String(s).replace(/&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|amp|quot|apos);/g, (m, e) => {
        if (e[0] === "#") {
            const cp = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
            return isFinite(cp) ? String.fromCodePoint(cp) : m;
        }
        return {
            lt: "<",
            gt: ">",
            amp: "&",
            quot: '"',
            apos: "'"
        }[e];
    });
}

function escapeXml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// -> the document element as { ns, name, attrs, children, text }, where ns
// is the namespace URI, name the local name, and text every bit of character
// data directly inside it. null for something that is not XML.
function parseXml(text) {
    const doc = {
        ns: "",
        name: "#document",
        attrs: {},
        children: [],
        text: ""
    };
    const stack = [
        {
            el: doc,
            scope: {
                xml: "http://www.w3.org/XML/1998/namespace"
            }
        }
    ];
    const re = /<!--[\s\S]*?-->|<!\[CDATA\[([\s\S]*?)\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<\/\s*([^\s>]+)\s*>|<([^\s\/>]+)((?:\s+[^\s=\/>]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|([^<]+)/g;
    const attrRe = /([^\s=\/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
    const src = String(text || "");
    let m;
    while ((m = re.exec(src)) !== null) {
        const top = stack[stack.length - 1];
        if (m[1] !== undefined) {
            top.el.text += m[1];
        } else if (m[6] !== undefined) {
            top.el.text += decodeEntities(m[6]);
        } else if (m[3] !== undefined) {
            const scope = Object.assign({}, top.scope);
            const raw = {};
            let a;
            attrRe.lastIndex = 0;
            while ((a = attrRe.exec(m[4] || "")) !== null) {
                const value = decodeEntities(a[2] !== undefined ? a[2] : a[3]);
                if (a[1] === "xmlns")
                    scope[""] = value;
                else if (a[1].indexOf("xmlns:") === 0)
                    scope[a[1].slice(6)] = value;
                else
                    raw[a[1]] = value;
            }
            const colon = m[3].indexOf(":");
            const prefix = colon >= 0 ? m[3].slice(0, colon) : "";
            const el = {
                ns: scope[prefix] || "",
                name: colon >= 0 ? m[3].slice(colon + 1) : m[3],
                attrs: {},
                children: [],
                text: ""
            };
            for (const k in raw)
                el.attrs[k.indexOf(":") >= 0 ? k.slice(k.indexOf(":") + 1) : k] = raw[k];
            top.el.children.push(el);
            if (m[5] !== "/")
                stack.push({
                    el: el,
                    scope: scope
                });
        } else if (m[2] !== undefined) {
            if (stack.length > 1)
                stack.pop();
        }
    }
    return doc.children[0] || null;
}

function child(el, ns, name) {
    return el ? el.children.find(c => c.ns === ns && c.name === name) || null : null;
}

function childrenOf(el, ns, name) {
    return el ? el.children.filter(c => c.ns === ns && c.name === name) : [];
}

// ---------------------------------------------------------------- multistatus

function _statusCode(line) {
    const m = /^\s*HTTP\/[\d.]+\s+(\d{3})/i.exec(String(line || ""));
    return m ? parseInt(m[1], 10) : 0;
}

// Multistatus XML -> [{ href, status, props }] with props keyed by
// "namespace|name" and holding only the properties the server answered with
// a 2xx -- a 404 propstat says the property does not exist there.
// null when the body is not a multistatus at all.
function parseMultistatus(text) {
    const root = parseXml(text);
    if (!root || root.ns !== DAV || root.name !== "multistatus")
        return null;
    return childrenOf(root, DAV, "response").map(r => {
        const hrefEl = child(r, DAV, "href");
        const props = {};
        for (const ps of childrenOf(r, DAV, "propstat")) {
            const code = _statusCode((child(ps, DAV, "status") || {}).text);
            if (code < 200 || code > 299)
                continue;
            const prop = child(ps, DAV, "prop");
            for (const p of prop ? prop.children : [])
                props[p.ns + "|" + p.name] = p;
        }
        return {
            href: hrefEl ? hrefEl.text.trim() : "",
            status: _statusCode((child(r, DAV, "status") || {}).text),
            props: props
        };
    });
}

function propText(response, ns, name) {
    const p = response.props[ns + "|" + name];
    return p ? p.text.trim() : "";
}

// calendar-data is text that matters to the byte: no trimming.
function propRaw(response, ns, name) {
    const p = response.props[ns + "|" + name];
    return p ? p.text : "";
}

function propHref(response, ns, name) {
    const p = response.props[ns + "|" + name];
    const h = p ? child(p, DAV, "href") : null;
    return h ? h.text.trim() : "";
}

function isCalendar(response) {
    const rt = response.props[DAV + "|resourcetype"];
    return !!child(rt, CALDAV, "calendar");
}

// A calendar that names no component set takes any component (RFC 4791 5.2.3).
function supportsTodo(response) {
    const set = response.props[CALDAV + "|supported-calendar-component-set"];
    if (!set)
        return true;
    return childrenOf(set, CALDAV, "comp").some(c => String(c.attrs.name || "").toUpperCase() === "VTODO");
}

// -------------------------------------------------------------- request bodies

var NAMESPACES = {
    "DAV:": "d",
    "urn:ietf:params:xml:ns:caldav": "c",
    "http://calendarserver.org/ns/": "cs"
};

// [[namespace, name], ...] -> a PROPFIND body asking for those properties.
function propfind(propList) {
    const body = propList.map(p => "<" + NAMESPACES[p[0]] + ":" + p[1] + "/>").join("");
    return '<?xml version="1.0" encoding="utf-8"?>\n<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/"><d:prop>' + body + "</d:prop></d:propfind>";
}

// ----------------------------------------------------------------------- URLs

function origin(url) {
    const m = /^(https?:\/\/[^\/?#]+)/i.exec(String(url || ""));
    return m ? m[1] : "";
}

function pathOf(url) {
    const m = /^https?:\/\/[^\/?#]+([^?#]*)/i.exec(String(url || ""));
    return m ? m[1] || "/" : "";
}

// An href from a response, against the URL the request went to. Servers send
// absolute paths almost always; full URLs and relative ones are handled too.
function resolve(base, href) {
    const h = String(href || "");
    if (/^https?:\/\//i.test(h))
        return h;
    if (h[0] === "/")
        return origin(base) + h;
    const dir = pathOf(base).replace(/[^\/]*$/, "");
    return origin(base) + dir + h;
}

function withSlash(url) {
    return /\/$/.test(url) ? url : url + "/";
}

// Paths compared the way the server means them: %-escapes decoded and a
// trailing slash ignored, so /main and /main/ and /m%61in/ are one collection.
function samePath(a, b) {
    const norm = u => {
        let p = /^https?:\/\//i.test(u) ? pathOf(u) : String(u || "");
        try {
            p = decodeURIComponent(p);
        } catch (e) {}
        return p.replace(/\/+$/, "");
    };
    return norm(a) === norm(b);
}

function lastSegment(url) {
    let s = (/^https?:\/\//i.test(url) ? pathOf(url) : String(url || "")).replace(/\/+$/, "");
    s = s.slice(s.lastIndexOf("/") + 1);
    try {
        return decodeURIComponent(s);
    } catch (e) {
        return s;
    }
}

// Where to start looking for the task list, from what was typed as the
// server. A bare address is a Nextcloud's own (remote.php/dav, also below a
// subfolder install), then the standard /.well-known/caldav, then the server
// root, which is where Radicale and some others keep everything. An address
// that already points into remote.php -- or a list's own link, copied out of
// Nextcloud -- is used as it is.
function startUrls(server) {
    let s = String(server || "").trim();
    if (!s)
        return [];
    if (!/^https?:\/\//i.test(s))
        s = "https://" + s;
    if (/\/remote\.php\//i.test(s + "/"))
        return [withSlash(s)];
    const base = s.replace(/\/+$/, "");
    return [base + "/remote.php/dav/", base + "/.well-known/caldav", base + "/"];
}

// One char per UTF-8 byte.
function _utf8(s) {
    let out = "";
    for (const ch of String(s)) {
        const cp = ch.codePointAt(0);
        if (cp < 0x80)
            out += String.fromCharCode(cp);
        else if (cp < 0x800)
            out += String.fromCharCode(0xc0 | (cp >> 6), 0x80 | (cp & 63));
        else if (cp < 0x10000)
            out += String.fromCharCode(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        else
            out += String.fromCharCode(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    }
    return out;
}

// "Basic dXNlcjpwYXNz" for user and password, UTF-8 then base64 -- written
// out here because node has no Qt.btoa.
function basicAuth(user, password) {
    const bytes = _utf8(String(user) + ":" + String(password));
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let out = "";
    for (let i = 0; i < bytes.length; i += 3) {
        const a = bytes.charCodeAt(i), b = bytes.charCodeAt(i + 1), c = bytes.charCodeAt(i + 2);
        const n = (a << 16) | ((b || 0) << 8) | (c || 0);
        out += chars[(n >> 18) & 63] + chars[(n >> 12) & 63] + (i + 1 < bytes.length ? chars[(n >> 6) & 63] : "=") + (i + 2 < bytes.length ? chars[n & 63] : "=");
    }
    return "Basic " + out;
}
