.pragma library

// Filter syntax: whitespace-separated tokens, ANDed together.
//   whatsapp                bare term — matches title, body or app
//   title:whatsapp          only the title/summary
//   app:signal               only the app name
//   body:"good morning"      quoted phrase, any field
//   urgency:critical          low | normal | critical
//   -app:spotify              negate a token
//
// Fields are aliases onto the plain-object shape NotificationService.historyList
// uses: { summary, body, appName, urgency, timestamp, image, appIcon, id }.

const FIELD_ALIASES = {
    "title": "summary",
    "summary": "summary",
    "body": "body",
    "app": "appName",
    "appname": "appName",
    "urgency": "urgency"
};

const URGENCY_NAMES = {
    "0": "low",
    "1": "normal",
    "2": "critical"
};

function tokenize(expr) {
    const re = /-?\w+:"[^"]*"|-?\w+:'[^']*'|-?\w+:\S+|"[^"]*"|'[^']*'|\S+/g;
    return expr.match(re) || [];
}

function stripQuotes(value) {
    if (value.length >= 2) {
        const first = value[0];
        const last = value[value.length - 1];
        if ((first === '"' && last === '"') || (first === "'" && last === "'"))
            return value.slice(1, -1);
    }
    return value;
}

function parseToken(raw) {
    let tok = raw;
    let negate = false;
    if (tok.startsWith("-") && tok.length > 1) {
        negate = true;
        tok = tok.slice(1);
    }

    const colon = tok.indexOf(":");
    let field = null;
    let value = tok;
    if (colon > 0) {
        const prefix = tok.slice(0, colon).toLowerCase();
        if (FIELD_ALIASES[prefix]) {
            field = FIELD_ALIASES[prefix];
            value = tok.slice(colon + 1);
        }
    }

    value = stripQuotes(value).toLowerCase();
    return {
        negate: negate,
        field: field,
        value: value
    };
}

// Returns a list of tokens, or [] for "no filter" (matches everything).
function parseFilter(expr) {
    if (!expr)
        return [];
    const trimmed = expr.trim();
    if (!trimmed)
        return [];
    return tokenize(trimmed).map(parseToken).filter(t => t.value.length > 0);
}

function fieldValue(item, field) {
    switch (field) {
    case "summary":
        return (item.summary || "").toLowerCase();
    case "body":
        return (item.body || "").toLowerCase();
    case "appName":
        return (item.appName || "").toLowerCase();
    case "urgency":
        return URGENCY_NAMES[String(item.urgency)] || String(item.urgency || "");
    default:
        return "";
    }
}

function matchesToken(item, token) {
    var hit;
    if (token.field) {
        hit = fieldValue(item, token.field).indexOf(token.value) !== -1;
    } else {
        hit = fieldValue(item, "summary").indexOf(token.value) !== -1 || fieldValue(item, "body").indexOf(token.value) !== -1 || fieldValue(item, "appName").indexOf(token.value) !== -1;
    }
    return token.negate ? !hit : hit;
}

// tokens list is the output of parseFilter(); [] always matches.
function matches(item, tokens) {
    if (!tokens || tokens.length === 0)
        return true;
    for (var i = 0; i < tokens.length; i++) {
        if (!matchesToken(item, tokens[i]))
            return false;
    }
    return true;
}

// ------------------------------------------------------------------------
// Structured per-category conditions: { field: "any"|"title"|"content"|"app"|
// "urgency", mode: "include"|"exact"|"exclude", value: string }. This is what
// the category editor builds; the free-text syntax above stays reserved for
// the search bar.

const CONDITION_FIELD_MAP = {
    "title": "summary",
    "content": "body",
    "app": "appName",
    "urgency": "urgency"
};
const CONDITION_ANY_FIELDS = ["title", "content", "app"];

function matchesCondition(item, cond) {
    const value = (cond.value || "").trim().toLowerCase();
    if (!value)
        return true;

    function testField(key) {
        const fv = fieldValue(item, CONDITION_FIELD_MAP[key]);
        return cond.mode === "exact" ? fv === value : fv.indexOf(value) !== -1;
    }

    const field = cond.field && CONDITION_FIELD_MAP[cond.field] ? cond.field : "any";
    const hit = field === "any" ? CONDITION_ANY_FIELDS.some(testField) : testField(field);
    return cond.mode === "exclude" ? !hit : hit;
}

// conditions is a plain array from a category; [] or missing always matches.
function matchesConditions(item, conditions) {
    if (!conditions || conditions.length === 0)
        return true;
    for (var i = 0; i < conditions.length; i++) {
        if (!matchesCondition(item, conditions[i]))
            return false;
    }
    return true;
}

// Upgrades a category saved before the structured-condition editor existed
// (`{ name, filter: "title:whatsapp" }`, the free-text query syntax) into one
// bare "any/include" condition carrying the old string verbatim, so it keeps
// matching exactly what it matched before and still shows up as an editable
// row afterward.
function migrateCategory(cat) {
    if (!cat)
        return cat;
    if (Array.isArray(cat.conditions))
        return cat;
    if (typeof cat.filter === "string") {
        return {
            name: cat.name,
            conditions: [{
                    field: "any",
                    mode: "include",
                    value: cat.filter
                }]
        };
    }
    return {
        name: cat.name,
        conditions: []
    };
}
