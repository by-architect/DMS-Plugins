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
    if (SCHEME_URL_RE.test(text) || BARE_WWW_RE.test(text) || MAIL_MAGNET_RE.test(text))
        return "url";
    return "text";
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
function describe(raw) {
    var text = (raw || "").toString().trim();
    var detail = {
        type: classify(text),
        text: text,
        path: "",
        basename: "",
        dirname: "",
        ext: "",
        color: ""
    };

    if (detail.type === "path") {
        var path = /^file:\/\//i.test(text) ? decodeFileUri(text) : text;
        var slash = path.lastIndexOf("/");
        var basename = slash >= 0 ? path.substring(slash + 1) : path;
        var dot = basename.lastIndexOf(".");

        detail.path = path;
        detail.basename = basename;
        detail.dirname = slash > 0 ? path.substring(0, slash) : (slash === 0 ? "/" : "");
        detail.ext = (dot > 0 && dot < basename.length - 1) ? basename.substring(dot + 1).toLowerCase() : "";
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

function matches(action, detail) {
    if (!action || !detail)
        return false;
    if (action.enabled === false)
        return false;
    if ((action.group || "text") !== detail.type)
        return false;
    if (detail.type === "path" && !extensionMatches(action, detail))
        return false;

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
    "terminal": 10
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
        ctx.terminal || ""
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
function substitute(command, replacer) {
    return String(command || "").replace(/"?\$\{([A-Za-z]+)\}"?/g, function (match, name) {
        var slot = PLACEHOLDERS[name];
        return slot === undefined ? match : replacer(slot);
    });
}

function shellEscape(str) {
    return "'" + String(str === undefined || str === null ? "" : str).replace(/'/g, "'\\''") + "'";
}

// Everything runs detached with no terminal, so a command that takes a while
// has no other way to tell you it finished. The action's own text is left
// untouched -- the epilogue is appended at run time, and only when the action
// asks for it, so turning the toggle off leaves nothing behind.
function notifyEpilogue() {
    return [
        "",
        "__dms_rc=$?",
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

    // Every value is quoted so it stays one word -- except the terminal, which
    // is a command plus its flags ("ghostty -e") and has to be split into
    // separate argv entries to be runnable at all.
    var script = substitute(action.command, function (slot) {
        return slot === 10 ? '${=' + slot + '}' : '"${' + slot + '}"';
    });
    if (!script.trim())
        return null;

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
    return substitute(action.command, function (slot) {
        return shellEscape(vals[slot]);
    });
}
