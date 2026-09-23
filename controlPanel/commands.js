.pragma library

// Recognizes a "<command> <query>" prefix in the search bar, e.g. "wifi home"
// or "bt sony". Everything after the first whitespace is the query; an
// unrecognized or missing prefix means "no active command".

const COMMAND_ALIASES = {
    "wifi": "wifi",
    "wi-fi": "wifi",
    "w": "wifi",
    "bluetooth": "bluetooth",
    "bt": "bluetooth",
    "b": "bluetooth",
    "speaker": "speaker",
    "speakers": "speaker",
    "audio": "speaker",
    "output": "speaker",
    "s": "speaker"
};

function parseCommand(text) {
    const trimmed = (text || "").trim();
    if (!trimmed)
        return {
            command: null,
            query: ""
        };

    const spaceIdx = trimmed.indexOf(" ");
    const firstWord = (spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx)).toLowerCase();
    const command = COMMAND_ALIASES[firstWord];
    if (!command)
        return {
            command: null,
            query: trimmed
        };

    const query = spaceIdx === -1 ? "" : trimmed.slice(spaceIdx + 1).trim();
    return {
        command: command,
        query: query
    };
}

// Case-insensitive substring match; an empty query matches everything.
function matches(haystack, query) {
    if (!query)
        return true;
    return (haystack || "").toLowerCase().includes(query.toLowerCase());
}
