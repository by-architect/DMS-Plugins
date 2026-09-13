.pragma library

// "now", "4m", "2h", "3d" -- the leading age stamp on every line. Kept short
// because it shares a single line with everything else.
function compactAge(date) {
    if (!date)
        return "";
    const ms = Date.now() - date.getTime();
    if (!isFinite(ms) || ms < 0)
        return "now";
    const min = Math.floor(ms / 60000);
    if (min < 1)
        return "now";
    if (min < 60)
        return min + "m";
    const hours = Math.floor(min / 60);
    if (hours < 24)
        return hours + "h";
    return Math.floor(hours / 24) + "d";
}

// Collapse a notification body to something that can live on one line: drop
// the markup DMS allows in bodies, then fold every run of whitespace (including
// the newlines that multi-line bodies are full of) into single spaces.
function oneLine(text) {
    if (!text)
        return "";
    return text.replace(/<br\s*\/?>/gi, " ").replace(/<[^>]*>/g, "").replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/\s+/g, " ").trim();
}

// Lowercase app names read as chat handles, which is the look we are after --
// but only when the app didn't deliberately capitalise (e.g. "KDE Connect").
function appLabel(name) {
    if (!name)
        return "app";
    return name.trim();
}
