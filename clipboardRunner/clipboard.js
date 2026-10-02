.pragma library

// Everything the plugin knows about clipboard text lives here: what kind of
// thing it is, whether an action's filters accept it, and how the action's
// command line becomes an argv array.
//
// Deliberately pure JavaScript with no QML imports, so the same code answers
// the launcher and the settings preview, and so it can be exercised outside
// the shell.

// ----------------------------------------------------------------- groups

var GROUPS = [
    { id: "url", label: "Link", icon: "link" },
    { id: "color", label: "Colour", icon: "palette" },
    { id: "path", label: "File", icon: "folder" },
    { id: "text", label: "Text", icon: "text_fields" }
];

function groupLabel(id) {
    for (var i = 0; i < GROUPS.length; i++) {
        if (GROUPS[i].id === id)
            return GROUPS[i].label;
    }
    return "Text";
}

function groupIcon(id) {
    for (var i = 0; i < GROUPS.length; i++) {
        if (GROUPS[i].id === id)
            return GROUPS[i].icon;
    }
    return "text_fields";
}

// ------------------------------------------------------------- detection

var PATH_RE = /^(\/|~\/|\.\.?\/)[^\n\r]*$/;
var HEX_RE = /^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;
var FUNC_COLOR_RE = /^(rgb|rgba|hsl|hsla)\(\s*[^()\n]*\)$/i;
var SCHEME_URL_RE = /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/\S+$/;
var BARE_WWW_RE = /^www\.\S+\.\S+$/;
var MAIL_MAGNET_RE = /^(mailto|magnet):\S+$/i;
// The scp-style address git uses over ssh, git@github.com:owner/repo.git. It
// has no scheme, so without this it would be filed as plain text.
var SCP_GIT_RE = /^[\w.\-]+@[\w.\-]+:[^\s:\/][^\s:]*\/\S*$/;

// A clipboard entry belongs to exactly one group. file:// is claimed by the
// file group rather than the link group, because what you want to do with it
// is almost always a file operation.
function classify(text) {
    if (!text)
        return "text";
    if (/^file:\/\//i.test(text) || PATH_RE.test(text))
        return "path";
    if (HEX_RE.test(text) || FUNC_COLOR_RE.test(text))
        return "color";
    if (SCHEME_URL_RE.test(text) || BARE_WWW_RE.test(text) || MAIL_MAGNET_RE.test(text) || SCP_GIT_RE.test(text))
        return "url";
    return "text";
}

// Content copied as data rather than as a file: a recording put on the
// clipboard as video/mp4, a voice message, a PDF out of a viewer. The clipboard
// manager answers "paste" with any of these as if it were text -- the raw bytes
// -- so they are recognised by type first and written out to a file instead,
// where the file actions apply. Images have their own path and text-like types
// are left to paste. Returns the extension to give the file, or "" when the
// type is not one of these.
var DATA_EXT = {
    "video/mp4": "mp4", "video/x-matroska": "mkv", "video/matroska": "mkv", "video/webm": "webm",
    "video/quicktime": "mov", "video/x-msvideo": "avi", "video/avi": "avi", "video/mpeg": "mpg",
    "video/x-flv": "flv", "video/x-ms-wmv": "wmv", "video/x-m4v": "m4v", "video/mp2t": "ts",
    "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/flac": "flac", "audio/x-flac": "flac",
    "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/mp4": "m4a",
    "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/ogg": "ogg", "audio/opus": "opus",
    "audio/aiff": "aiff", "audio/x-aiff": "aiff",
    "application/pdf": "pdf", "application/zip": "zip", "application/x-7z-compressed": "7z",
    "application/gzip": "gz", "application/x-tar": "tar", "application/vnd.rar": "rar",
    "application/x-rar-compressed": "rar", "application/vnd.android.package-archive": "apk",
    "application/vnd.oasis.opendocument.text": "odt", "application/vnd.oasis.opendocument.spreadsheet": "ods",
    "application/vnd.oasis.opendocument.presentation": "odp", "application/msword": "doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
    "application/vnd.ms-excel": "xls", "application/vnd.ms-powerpoint": "ppt", "application/rtf": "rtf",
    "application/epub+zip": "epub", "video/3gpp": "3gp", "video/ogg": "ogv", "audio/x-ms-wma": "wma",
    "application/x-iso9660-image": "iso",
    "application/octet-stream": "bin"
};

function dataExt(mime) {
    var m = String(mime || "").toLowerCase().split(";")[0].trim();
    if (DATA_EXT[m])
        return DATA_EXT[m];
    if (!/^(video|audio|application)\/[a-z0-9.+\-]+$/.test(m))
        return "";
    if (/(json|xml|javascript|ecmascript|x-sh|shellscript|yaml|toml|sql|urlencoded)/.test(m))
        return "";
    var sub = m.split("/")[1];
    // A vendor type's name says nothing a file manager would recognise.
    if (sub.indexOf("vnd.") === 0)
        return "bin";
    return sub.replace(/^x-/, "").replace(/[^a-z0-9]/g, "") || "bin";
}

function decodeFileUri(uri) {
    var raw = uri.replace(/^file:\/\//i, "");
    var hash = raw.indexOf("#");
    if (hash >= 0)
        raw = raw.substring(0, hash);
    try {
        return decodeURIComponent(raw);
    } catch (e) {
        return raw;
    }
}

function expandHex(value) {
    var hex = value.substring(1);
    if (hex.length === 3 || hex.length === 4) {
        var expanded = "";
        for (var i = 0; i < hex.length; i++)
            expanded += hex[i] + hex[i];
        hex = expanded;
    }
    return "#" + hex.toLowerCase();
}

// The descriptor every other function in this file takes.
// isDir is not knowable from the string alone -- the launcher stats the path and
// passes the answer in, so that a folder and a file can be told apart without
// this file having to touch the filesystem.
function describe(raw, isDir) {
    var text = (raw || "").toString().trim();
    var detail = {
        type: classify(text),
        text: text,
        path: "",
        basename: "",
        dirname: "",
        ext: "",
        color: "",
        isDir: isDir === true
    };

    if (detail.type === "path") {
        var path = /^file:\/\//i.test(text) ? decodeFileUri(text) : text;
        var slash = path.lastIndexOf("/");
        var basename = slash >= 0 ? path.substring(slash + 1) : path;
        var dot = basename.lastIndexOf(".");

        detail.path = path;
        detail.basename = basename;
        detail.dirname = slash > 0 ? path.substring(0, slash) : (slash === 0 ? "/" : "");
        detail.ext = (!detail.isDir && dot > 0 && dot < basename.length - 1) ? basename.substring(dot + 1).toLowerCase() : "";
    } else if (detail.type === "color") {
        detail.color = HEX_RE.test(text) ? expandHex(text) : text;
    }

    return detail;
}

// --------------------------------------------------------------- filters

var OPERATORS = [
    { value: "any", label: "anything" },
    { value: "includes", label: "includes" },
    { value: "excludes", label: "excludes" },
    { value: "exact", label: "is exactly" },
    { value: "notexact", label: "is not exactly" },
    { value: "startsWith", label: "starts with" },
    { value: "endsWith", label: "ends with" },
    { value: "regex", label: "matches regex" },
    { value: "notRegex", label: "does not match regex" }
];

function operatorLabel(value) {
    for (var i = 0; i < OPERATORS.length; i++) {
        if (OPERATORS[i].value === value)
            return OPERATORS[i].label;
    }
    return "includes";
}

function operatorValue(label) {
    for (var i = 0; i < OPERATORS.length; i++) {
        if (OPERATORS[i].label === label)
            return OPERATORS[i].value;
    }
    return "includes";
}

function conditionMatches(condition, subject) {
    var op = (condition && condition.op) || "includes";
    if (op === "any")
        return true;

    var raw = (condition && condition.value !== undefined && condition.value !== null) ? String(condition.value) : "";
    var caseSensitive = condition && condition.caseSensitive === true;

    if (op === "regex" || op === "notRegex") {
        if (!raw)
            return op === "notRegex";
        var re;
        try {
            re = new RegExp(raw, caseSensitive ? "" : "i");
        } catch (e) {
            // A half-typed regex in the settings panel should simply not match,
            // rather than break the whole list.
            return false;
        }
        var hit = re.test(subject);
        return op === "regex" ? hit : !hit;
    }

    if (!raw)
        return true;

    var needle = caseSensitive ? raw : raw.toLowerCase();
    var hay = caseSensitive ? subject : subject.toLowerCase();

    if (op === "includes")
        return hay.indexOf(needle) !== -1;
    if (op === "excludes")
        return hay.indexOf(needle) === -1;
    if (op === "exact")
        return hay === needle;
    if (op === "notexact")
        return hay !== needle;
    if (op === "startsWith")
        return hay.lastIndexOf(needle, 0) === 0;
    if (op === "endsWith")
        return needle.length <= hay.length && hay.indexOf(needle, hay.length - needle.length) !== -1;
    return false;
}

function extensionMatches(action, detail) {
    var raw = (action && action.extensions ? String(action.extensions) : "").trim();
    if (!raw)
        return true;

    var wanted = raw.split(",").map(function (e) {
        return e.trim().replace(/^\./, "").toLowerCase();
    }).filter(function (e) {
        return e.length > 0;
    });

    return wanted.length === 0 || wanted.indexOf(detail.ext) !== -1;
}

var TARGETS = [
    { value: "any", label: "files and folders" },
    { value: "file", label: "files only" },
    { value: "dir", label: "folders only" }
];

function targetLabel(value) {
    for (var i = 0; i < TARGETS.length; i++) {
        if (TARGETS[i].value === value)
            return TARGETS[i].label;
    }
    return TARGETS[0].label;
}

function targetValue(label) {
    for (var i = 0; i < TARGETS.length; i++) {
        if (TARGETS[i].label === label)
            return TARGETS[i].value;
    }
    return "any";
}

function targetMatches(action, detail) {
    var target = (action && action.target) || "any";
    if (target === "dir")
        return detail.isDir === true;
    if (target === "file")
        return detail.isDir !== true;
    return true;
}

function matches(action, detail) {
    if (!action || !detail)
        return false;
    if (action.enabled === false)
        return false;
    if ((action.group || "text") !== detail.type)
        return false;
    if (detail.type === "path") {
        if (!targetMatches(action, detail))
            return false;
        // An extension filter is a statement about a file. A folder has no
        // extension, so an action that names any cannot be meant for one --
        // otherwise "convert to mp3" would offer itself for a directory.
        if (detail.isDir) {
            if (String((action.extensions || "")).trim().length > 0)
                return false;
        } else if (!extensionMatches(action, detail)) {
            return false;
        }
    }

    var conditions = action.conditions || [];
    for (var i = 0; i < conditions.length; i++) {
        if (!conditionMatches(conditions[i], detail.text))
            return false;
    }
    return true;
}

function matchAll(actions, detail) {
    var out = [];
    for (var i = 0; i < (actions || []).length; i++) {
        if (matches(actions[i], detail))
            out.push(actions[i]);
    }
    return out;
}

// ---------------------------------------------------------- placeholders

// Placeholder name -> shell positional. Clipboard text is handed to zsh as an
// argument rather than pasted into the script, so a copied "; rm -rf ~" is
// data to the command and never a second command.
var PLACEHOLDERS = {
    "clipboard": 1,
    "clipboardContent": 1,
    "content": 1,
    "clip": 1,
    "path": 2,
    "ext": 3,
    "basename": 4,
    "dirname": 5,
    "type": 6,
    "color": 7,
    "name": 8,
    "downloads": 9,
    "terminal": 10,
    "cache": 11
};

function placeholderHint(group) {
    var common = "${clipboard}  ${type}  ${downloads}";
    if (group === "color")
        return "${clipboard}  ${color}  ${type}";
    if (group === "path")
        return "${clipboard}  ${path}  ${ext}  ${basename}  ${dirname}  ${type}  ${downloads}";
    return common;
}

// ctx carries the two settings that presets read: where downloads go, and the
// terminal to use for the handful of actions that genuinely need one (nvim).
function values(action, detail, ctx) {
    ctx = ctx || {};
    return [
        "dms-clipboard-action",
        detail.text,
        detail.path,
        detail.ext,
        detail.basename,
        detail.dirname,
        detail.type,
        detail.color,
        actionLabel(action),
        ctx.downloads || "",
        ctx.terminal || "",
        ctx.cache || ""
    ];
}

function actionLabel(action) {
    if (!action)
        return "";
    var name = String(action.name || "").trim();
    return name || String(action.command || "").trim();
}

// Quotes already written around a placeholder are swallowed, because the
// replacement supplies its own. Without this, the natural "${clipboard}" would
// expand to ""${1}"" -- an empty string, an *unquoted* parameter, and another
// empty string -- and the value would word-split after all.
// Replaces each known ${name} with replacer(slot, quoting), where quoting is
// what the placeholder sits inside: "none", "double" or "single". The command
// is walked the way the shell reads it, because the right replacement depends
// on that -- `"Got ${clipboard}"` needs a bare ${1} where the string already
// is, while a lone ${clipboard} needs quotes of its own to stay one word.
// Eating a quote on either side of the placeholder instead, as this once did,
// turned `notify-send "Got ${clipboard}"` into `"Got "${1}"`: a quote left
// open, and a command that never ran. A backslash-escaped \${name} outside
// single quotes is left as typed. A $( ... ) starts afresh whatever it sits in
// -- `"?q=$(urlencode ${clipboard})"` is an unquoted word inside a command --
// so the quoting around one is put aside until its closing parenthesis.
function substitute(command, replacer) {
    var text = String(command || "");
    var out = "";
    var quoting = "none";
    var outer = [];   // per open $( ... ): the quoting around it, and its own ( depth
    var i = 0;
    while (i < text.length) {
        var c = text[i];
        if (quoting !== "single" && c === "\\" && i + 1 < text.length) {
            out += c + text[i + 1];
            i += 2;
            continue;
        }
        if (quoting !== "single" && c === "$" && text[i + 1] === "(") {
            outer.push({ quoting: quoting, parens: 0 });
            quoting = "none";
            out += "$(";
            i += 2;
            continue;
        }
        if (c === "$" && text[i + 1] === "{") {
            var m = /^\$\{([A-Za-z]+)\}/.exec(text.slice(i));
            if (m && PLACEHOLDERS[m[1]] !== undefined) {
                out += replacer(PLACEHOLDERS[m[1]], quoting);
                i += m[0].length;
                continue;
            }
        }
        if (c === "'" && quoting !== "double")
            quoting = quoting === "single" ? "none" : "single";
        else if (c === '"' && quoting !== "single")
            quoting = quoting === "double" ? "none" : "double";
        else if (quoting === "none" && outer.length > 0 && c === "(")
            outer[outer.length - 1].parens++;
        else if (quoting === "none" && outer.length > 0 && c === ")") {
            if (outer[outer.length - 1].parens > 0)
                outer[outer.length - 1].parens--;
            else
                quoting = outer.pop().quoting;
        }
        out += c;
        i++;
    }
    return out;
}

// The shell text that reads positional `slot` in the given quoting. Every
// value stays one word -- except the terminal, which is a command plus its
// flags ("ghostty -e") and has to be split into separate argv entries to be
// runnable at all; inside double quotes nothing is split, terminal included.
// Single quotes expand nothing, so the placeholder steps out of them and back.
function shellRef(slot, quoting) {
    var bare = slot === 10 ? '${=' + slot + '}' : '"${' + slot + '}"';
    if (quoting === "double")
        return '${' + slot + '}';
    if (quoting === "single")
        return "'" + bare + "'";
    return bare;
}

function shellEscape(str) {
    return "'" + String(str === undefined || str === null ? "" : str).replace(/'/g, "'\\''") + "'";
}

// True when the thing being acted on is a clipboard image the plugin wrote out
// itself, rather than a file that was already on disk somewhere.
function isCached(detail, ctx) {
    var cache = (ctx && ctx.cache) || "";
    return cache.length > 0 && detail && detail.path && detail.path.indexOf(cache + "/") === 0;
}

// Touched before the command runs, so afterwards "what did this produce" is
// answerable as "whatever in the cache is newer than this".
function stampPrologue() {
    return '__dms_stamp=$(mktemp)\n';
}

// An image that arrived as clipboard data has no home on disk, so its
// conversions have nowhere useful to land either -- you would have to go
// digging in the cache for them. Putting the result straight back on the
// clipboard is what you wanted when you copied the image in the first place,
// and it means conversions chain: convert, convert again, paste.
//
// Images go back as bytes, so pasting into an editor or a browser works.
// Anything else goes back as a file URI, which is what a file manager wants.
function copyBackEpilogue() {
    return [
        "",
        'if [ "$__dms_rc" -eq 0 ]; then',
        '    __dms_out=$(find "${11}" -maxdepth 1 -type f -newer "$__dms_stamp" ! -path "${2}" 2>/dev/null | head -n 1)',
        '    if [ -n "$__dms_out" ]; then',
        '        __dms_ext="${__dms_out:e:l}"',
        '        [ "$__dms_ext" = "jpg" ] && __dms_ext="jpeg"',
        '        case "$__dms_ext" in',
        '            png|jpeg|gif|webp|bmp|tiff|avif)',
        '                "${DMS_EXECUTABLE:-dms}" cl copy --type "image/$__dms_ext" < "$__dms_out" ;;',
        '            *)',
        '                printf \'file://%s\\r\\n\' "$__dms_out" | "${DMS_EXECUTABLE:-dms}" cl copy --type text/uri-list ;;',
        '        esac',
        '    fi',
        "fi",
        'rm -f "$__dms_stamp"'
    ].join("\n");
}

// Everything runs detached with no terminal, so a command that takes a while
// has no other way to tell you it finished. The action's own text is left
// untouched -- the epilogue is appended at run time, and only when the action
// asks for it, so turning the toggle off leaves nothing behind.
function notifyEpilogue() {
    return [
        "",
        'if [ "$__dms_rc" -eq 0 ]; then',
        '    notify-send -a "Clipboard Runner" "${8}" "Finished"',
        "else",
        '    notify-send -a "Clipboard Runner" -u critical "${8}" "Failed (exit $__dms_rc)"',
        "fi"
    ].join("\n");
}

// argv for Quickshell.execDetached:
//   zsh -c <script> dms-clipboard-action <clipboard> <path> <ext> <basename>
//                   <dirname> <type> <color> <name> <downloads> <terminal>
function resolveCommand(action, detail, ctx) {
    if (!action || !detail)
        return null;

    var script = substitute(action.command, shellRef);
    if (!script.trim())
        return null;

    // rc has to be captured before anything else runs, so the epilogues are
    // assembled in one piece rather than appended independently.
    const cached = isCached(detail, ctx);
    if (cached)
        script = stampPrologue() + script;
    if (cached || action.notify !== false)
        script += "\n__dms_rc=$?";
    if (cached)
        script += copyBackEpilogue();
    if (action.notify !== false)
        script += notifyEpilogue();

    return ["zsh", "-c", script].concat(values(action, detail, ctx));
}

// What the launcher shows under the action name. Display only -- the escaped
// string is never the thing that runs, and the notify epilogue is left out
// because it is plumbing rather than something you asked for.
function preview(action, detail, ctx) {
    if (!action || !detail)
        return "";
    var vals = values(action, detail, ctx);
    return substitute(action.command, function (slot, quoting) {
        var value = String(vals[slot] === undefined || vals[slot] === null ? "" : vals[slot]);
        if (quoting === "double")
            return value.replace(/[\\"$`]/g, "\\$&");
        if (quoting === "single")
            return "'" + shellEscape(value) + "'";
        return shellEscape(value);
    });
}
