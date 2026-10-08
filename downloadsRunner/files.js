.pragma library

// Everything about the listing that is not QML: reading find's output,
// matching a query against it, and what a row says about a file. Pure
// JavaScript with no QML imports, so it runs under node as well
// (tests/files.test.js).

var IMAGE_EXT = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "tiff", "tif", "avif", "svg", "heic", "heif"];
var VIDEO_EXT = ["mp4", "mkv", "avi", "mov", "webm", "flv", "wmv", "m4v", "mpg", "mpeg", "ts"];
var AUDIO_EXT = ["mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "wma", "aiff", "alac"];
var ARCHIVE_EXT = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "lzma", "cab", "deb", "rpm"];
var DOC_EXT = ["doc", "docx", "odt", "ods", "odp", "xls", "xlsx", "ppt", "pptx", "rtf", "epub"];
var TEXT_EXT = ["txt", "md", "csv", "json", "xml", "yaml", "yml", "toml", "log", "html", "nix", "sh", "py", "js", "go", "rs", "c", "cpp", "h"];
// Browsers and download managers write under one of these until they finish.
var PARTIAL_EXT = ["part", "crdownload", "download", "partial", "aria2"];
// What the launcher row can show as a thumbnail without a codec Qt may lack.
var PREVIEW_EXT = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg"];

function has(list, ext) {
    return list.indexOf(ext) !== -1;
}

// find -printf '%T@\t%s\t%y\t%P\n': modification time in seconds, size in
// bytes, type letter, then the path relative to the folder -- last, so a tab
// inside a file name cannot shift the fields before it.
function parseListing(text, base) {
    var root = String(base || "").replace(/\/+$/, "");
    var out = [];
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (!line)
            continue;
        var a = line.indexOf("\t");
        var b = a < 0 ? -1 : line.indexOf("\t", a + 1);
        var c = b < 0 ? -1 : line.indexOf("\t", b + 1);
        if (c < 0)
            continue;
        var mtime = parseFloat(line.slice(0, a));
        var size = parseInt(line.slice(a + 1, b), 10);
        var type = line.slice(b + 1, c);
        var rel = line.slice(c + 1);
        if (!rel || !isFinite(mtime))
            continue;

        var slash = rel.lastIndexOf("/");
        var name = slash >= 0 ? rel.slice(slash + 1) : rel;
        var isDir = type === "d";
        var dot = name.lastIndexOf(".");
        var ext = !isDir && dot > 0 && dot < name.length - 1 ? name.slice(dot + 1).toLowerCase() : "";
        out.push({
            rel: rel,
            name: name,
            dir: slash >= 0 ? rel.slice(0, slash) : "",
            path: root + "/" + rel,
            isDir: isDir,
            size: isFinite(size) ? size : 0,
            mtimeMs: mtime * 1000,
            ext: ext,
            partial: has(PARTIAL_EXT, ext),
            depth: rel.split("/").length - 1
        });
    }
    return out;
}

// Every word of the query has to appear somewhere in the path below the
// folder, so "invoice march" finds Invoices/2026-march.pdf. What decides the
// order: the whole query in the file's own name (best at its start), how many
// words land in the name rather than in a folder above it, and how shallow it
// sits. Equal scores keep the listing's order, which is newest first. With no
// query, the newest files are the answer.
function search(entries, query, limit) {
    var max = limit > 0 ? limit : 30;
    var q = String(query || "").trim().toLowerCase();
    if (!q)
        return entries.slice(0, max);

    var words = q.split(/\s+/);
    var scored = [];
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var rel = e.rel.toLowerCase();
        var all = true;
        for (var w = 0; w < words.length; w++) {
            if (rel.indexOf(words[w]) === -1) {
                all = false;
                break;
            }
        }
        if (!all)
            continue;

        var name = e.name.toLowerCase();
        var score = 0;
        if (name === q)
            score += 1000;
        else if (name.indexOf(q) === 0)
            score += 600;
        else if (name.indexOf(q) !== -1)
            score += 400;
        for (var k = 0; k < words.length; k++) {
            if (name.indexOf(words[k]) !== -1)
                score += 50;
        }
        score -= e.depth * 10;
        scored.push({
            entry: e,
            score: score,
            order: i
        });
    }
    scored.sort(function (x, y) {
        return (y.score - x.score) || (x.order - y.order);
    });
    return scored.slice(0, max).map(function (s) {
        return s.entry;
    });
}

function iconFor(e) {
    if (e.isDir)
        return "folder";
    if (e.partial)
        return "downloading";
    var x = e.ext;
    if (has(IMAGE_EXT, x))
        return "image";
    if (has(VIDEO_EXT, x))
        return "movie";
    if (has(AUDIO_EXT, x))
        return "music_note";
    if (x === "pdf")
        return "picture_as_pdf";
    if (has(ARCHIVE_EXT, x))
        return "folder_zip";
    if (x === "apk" || x === "xapk" || x === "apks")
        return "android";
    if (x === "appimage")
        return "install_desktop";
    if (x === "iso" || x === "img")
        return "album";
    if (x === "torrent")
        return "magnet_bookmark";
    if (has(DOC_EXT, x))
        return "description";
    if (has(TEXT_EXT, x))
        return "article";
    return "draft";
}

function previewable(e) {
    return !e.isDir && !e.partial && has(PREVIEW_EXT, e.ext);
}

function sizeText(bytes) {
    var n = Number(bytes) || 0;
    if (n < 1024)
        return n + " B";
    var units = ["KB", "MB", "GB", "TB"];
    var i = -1;
    do {
        n /= 1024;
        i++;
    } while (n >= 1024 && i < units.length - 1);
    return (n >= 100 ? Math.round(n) : n.toFixed(1)) + " " + units[i];
}

function agoText(ms, nowMs) {
    var s = Math.max(0, Math.round((nowMs - ms) / 1000));
    if (s < 60)
        return "just now";
    var m = Math.round(s / 60);
    if (m < 60)
        return m + " min ago";
    var h = Math.round(m / 60);
    if (h < 24)
        return h + " h ago";
    var d = Math.round(h / 24);
    if (d === 1)
        return "yesterday";
    if (d < 30)
        return d + " days ago";
    var date = new Date(ms);
    return date.getFullYear() + "-" + ("0" + (date.getMonth() + 1)).slice(-2) + "-" + ("0" + date.getDate()).slice(-2);
}

// The line under a file's name: where it sits when that is not the top of
// the folder, how big it is, when it changed -- and that it is still
// arriving, for a download not finished yet.
function describe(e, nowMs) {
    var parts = [];
    if (e.dir)
        parts.push(e.dir + "/");
    if (e.partial)
        parts.push("still downloading");
    if (!e.isDir)
        parts.push(sizeText(e.size));
    else
        parts.push("folder");
    parts.push(agoText(e.mtimeMs, nowMs));
    return parts.join(" · ");
}

// file:// URI for a path, each segment percent-encoded. encodeURIComponent
// leaves ' ( ) ! * ~ alone; the apostrophe is encoded as well, since the URI
// is also handed to a D-Bus call written inside single quotes.
function fileUri(path) {
    return "file://" + String(path).split("/").map(function (seg) {
        return encodeURIComponent(seg).replace(/'/g, "%27");
    }).join("/");
}
