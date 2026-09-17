.pragma library

// Wallhaven's public search API. No key needed for SFW results, which is all
// this plugin ever requests.
function searchUrl(query, page) {
    return "https://wallhaven.cc/api/v1/search?page=" + page + "&sorting=relevance&purity=100&q=" + encodeURIComponent(query || "");
}

// Raw curl stdout -> normalized {key, thumb, full, lastPage} shape, or null
// on anything unparseable (network failure, rate limit, curl error page).
function parseResults(raw) {
    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (e) {
        return null;
    }
    const data = parsed && parsed.data;
    if (!Array.isArray(data))
        return null;

    const items = data.map(item => ({
                key: item.id,
                thumb: item?.thumbs?.large || item?.thumbs?.original || "",
                full: item.path || "",
                width: item.dimension_x || 0,
                height: item.dimension_y || 0
            }));

    return {
        items: items,
        lastPage: parsed?.meta?.last_page || 1
    };
}

// A Wallhaven download URL always ends in the real extension; fall back to
// jpg for the rare case that's somehow missing.
function extensionFor(url) {
    const m = (url || "").match(/\.([a-zA-Z0-9]+)(?:\?.*)?$/);
    return m ? m[1] : "jpg";
}
