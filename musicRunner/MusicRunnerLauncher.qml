import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Launcher provider backed by `mpc`, MPD's command-line client. Searches up to
// five independently-toggleable categories at once (songs, playlists, artists,
// albums, and songs found inside playlists) and merges them into one ranked
// list.
//
// A playlist is one row no matter how it matched - by its own name, or by a
// track found inside it - since the result-row layout is a single elided
// line (no real multi-line rows exist in this launcher), so "list name, then
// each matching track indented under it" becomes "list name, matching
// tracks summarized in the subtitle". Selecting that row always acts on the
// playlist, never on one track inside it.
//
// Three async subsystems run side by side, each with its own Process so none
// waits behind another:
//  - the query chain (songs/artists/albums): a fresh mpc search per category,
//    re-run whenever the typed query settles.
//  - the poll chain (playlists, and songs-inside-playlists): mpc search
//    doesn't cover saved-playlist contents, so those are fetched ahead of time
//    on a throttle and filtered locally, the same way tmuxRunner polls
//    `tmux list-sessions` instead of re-listing per keystroke.
//  - the action chain: resolves a playlist's/artist's/album's file list on
//    demand when "add after current song" is picked, since mpc can only
//    insert file paths, not playlist/artist/album names.
// getItems() never blocks on any of them - it always answers from cache
// immediately, and results land later via PluginService.requestLauncherUpdate().
Item {
    id: root

    readonly property string pluginId: "musicRunner"

    property var pluginService: null
    property string trigger: "mpd "

    signal itemsChanged

    // Settings, mirrored from plugin data (see MusicRunnerSettings.qml)
    property string mpcBin: "mpc"
    property string mpdHost: ""
    property string mpdPort: ""
    property bool searchSongs: true
    property bool searchPlaylists: true
    property bool searchArtists: true
    property bool searchAlbums: true
    property bool searchPlaylistTracks: true
    property int maxPerCategory: 6

    readonly property int _minChars: 2
    readonly property int _namesIntervalMs: 8000
    readonly property int _tracksIntervalMs: 30000
    readonly property int _maxInsertTracks: 30
    readonly property string _songFormat: "%file%\t%artist%\t%title%\t%time%"
    readonly property string _albumFormat: "%album%\t%albumartist%\t%artist%"
    readonly property string _trackFormat: "%artist%\t%title%\t%file%"

    // Enter always runs the first action in the kind's list; right-click
    // exposes all of them in this order. Songs get a non-destructive default
    // (cut in line, keep the rest of the queue); playlists/artists/albums
    // default to replacing the queue, matching how most music apps treat
    // "open an album/playlist" as "start listening to just this".
    readonly property var _songActions: [
        { id: "insertPlayNow", icon: "play_circle", label: "Add after current song and play" },
        { id: "insertNext", icon: "playlist_play", label: "Add after current song" },
        { id: "replace", icon: "restart_alt", label: "Replace queue and play" },
        { id: "enqueueEnd", icon: "playlist_add", label: "Add to end of queue" }
    ]
    readonly property var _groupActions: [
        { id: "replace", icon: "restart_alt", label: "Replace queue and play" },
        { id: "enqueueEnd", icon: "playlist_add", label: "Add to end of queue" },
        { id: "insertNext", icon: "playlist_play", label: "Add after current song" }
    ]

    function _actionsForKind(kind) {
        return kind === "song" ? _songActions : _groupActions;
    }

    Component.onCompleted: _loadSettings()
    onPluginServiceChanged: _loadSettings()

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId !== root.pluginId)
                return;
            root._loadSettings();
            root._queryCache = ({});
            root._queryCacheOrder = [];
            root._plNamesEverFetched = false;
            root._plTracksEverFetched = false;
            root.itemsChanged();
        }
    }

    function _loadSettings() {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData(pluginId, "trigger", "mpd ");
        mpcBin = pluginService.loadPluginData(pluginId, "mpcBin", "mpc");
        mpdHost = pluginService.loadPluginData(pluginId, "mpdHost", "");
        mpdPort = pluginService.loadPluginData(pluginId, "mpdPort", "");
        searchSongs = pluginService.loadPluginData(pluginId, "searchSongs", true);
        searchPlaylists = pluginService.loadPluginData(pluginId, "searchPlaylists", true);
        searchArtists = pluginService.loadPluginData(pluginId, "searchArtists", true);
        searchAlbums = pluginService.loadPluginData(pluginId, "searchAlbums", true);
        searchPlaylistTracks = pluginService.loadPluginData(pluginId, "searchPlaylistTracks", true);
        maxPerCategory = pluginService.loadPluginData(pluginId, "maxPerCategory", 6);
    }

    // ---------------------------------------------------------------- launcher

    function getItems(query) {
        _maybePoll();

        const q = (query || "").trim();

        // Shown immediately, regardless of query length, so opening the
        // trigger while MPD is down says so up front instead of just
        // returning nothing or "Searching...". Clears itself the moment any
        // subsystem's next attempt succeeds - no action needed once MPD
        // comes back, though "Press Enter to retry" forces an immediate
        // attempt instead of waiting for the next scheduled poll.
        if (_mpdError)
            return [_statusItem("cloud_off", "MPD not connected", _mpdError + "  ·  Press Enter to retry", "retryConnection")];

        if (q.length === 0)
            return _emptyQueryItems();

        if (q.length < _minChars)
            return [_statusItem("keyboard", "Keep typing…", "At least " + _minChars + " characters needed")];

        _maybeStartQuery(q);

        const results = [];
        const cached = _queryCacheGet(q);

        if (searchSongs && cached)
            for (const s of cached.songs)
                results.push({ kind: "song", entry: s });
        if (searchArtists && cached)
            for (const a of cached.artists)
                results.push({ kind: "artist", entry: { name: a } });
        if (searchAlbums && cached)
            for (const a of cached.albums)
                results.push({ kind: "album", entry: a });
        if (searchPlaylists || searchPlaylistTracks)
            for (const p of _matchPlaylists(q))
                results.push({ kind: "playlist", entry: p });

        const ranked = _rankResults(results, q);
        const items = ranked.slice(0, 40).map((r, i) => _toItem(r, 9000 - i));

        if (items.length === 0) {
            if (cached || (!searchSongs && !searchArtists && !searchAlbums))
                return [_statusItem("search_off", "No matches for \"" + q + "\"", "")];
            return [_statusItem("hourglass_empty", "Searching MPD…", "")];
        }

        return items;
    }

    function executeItem(item) {
        if (!item)
            return;

        if (item.action === "retryConnection") {
            // Reset the poll throttle so this doesn't just wait out the
            // normal 8s/30s cycle, then immediately retry whatever's
            // relevant: the playlist poll, and the active query if there is
            // one.
            _plNamesLastFetchAt = 0;
            _plTracksLastFetchAt = 0;
            _maybePoll();
            if (_desiredQuery.length >= _minChars)
                _maybeStartQuery(_desiredQuery, true);
            return;
        }

        if (!item.mpdKind)
            return;
        const table = _actionsForKind(item.mpdKind);
        if (table.length > 0)
            _runKindAction(item, table[0].id);
    }

    function getContextMenuActions(item) {
        if (!item || !item.mpdKind)
            return [];

        const actions = _actionsForKind(item.mpdKind).map(a => ({
            icon: a.icon,
            text: a.label,
            action: () => root._runKindAction(item, a.id)
        }));

        if (item.mpdKind === "song") {
            actions.push({
                icon: "content_copy",
                text: "Copy file path",
                action: () => {
                    Quickshell.execDetached(["dms", "cl", "copy", item.mpdEntry.file]);
                    root._toast("Copied", item.mpdEntry.file);
                }
            });
        } else {
            actions.push({
                icon: "content_copy",
                text: "Copy name",
                action: () => {
                    Quickshell.execDetached(["dms", "cl", "copy", item.mpdEntry.name]);
                    root._toast("Copied", item.mpdEntry.name);
                }
            });
        }

        return actions;
    }

    function _emptyQueryItems() {
        if (searchPlaylists) {
            const names = _plNames.slice(0, Math.max(1, maxPerCategory) * 2);
            if (names.length > 0)
                return names.map((n, i) => _toItem({ kind: "playlist", entry: { name: n, matchedTracks: [] } }, 9000 - i));
        }
        return [_statusItem("search", "Search your MPD library", "Type a song, playlist, artist or album name")];
    }

    // ------------------------------------------------------------ query chain

    property var _queryCache: ({})
    property var _queryCacheOrder: []
    readonly property int _queryCacheLimit: 30

    property string _desiredQuery: ""
    property string _queryPending: ""
    property var _queryFetchQueue: []
    property var _queryAccum: ({ songs: [], artists: [], albums: [] })
    property bool _queryHadError: false

    // Single shared status for "can we currently talk to MPD at all",
    // updated by every subsystem (query chain, poll chain, actions). Empty
    // means the most recent attempt succeeded. This is what getItems()
    // surfaces as a top-level "MPD not connected" row - a failed mpc call is
    // overwhelmingly a connectivity problem in practice, not a per-query one.
    property string _mpdError: ""

    function _reportMpdOk() {
        _mpdError = "";
    }

    function _reportMpdError(code, err) {
        _mpdError = code === -1 ? "Timed out connecting to MPD." : (_firstErrorLine(err) || ("mpc exited with code " + code + "."));
    }

    Timer {
        id: queryDebounce
        interval: 250
        repeat: false
        onTriggered: root._maybeStartQuery(root._desiredQuery, true)
    }

    function _maybeStartQuery(q, settled) {
        if (_queryCacheGet(q))
            return;
        if (!settled) {
            _desiredQuery = q;
            queryDebounce.restart();
            return;
        }
        _desiredQuery = q;
        if (queryWorker.busy)
            return;
        _beginQueryChain(q);
    }

    function _beginQueryChain(q) {
        _queryPending = q;
        _queryAccum = { songs: [], artists: [], albums: [] };
        _queryFetchQueue = [];
        _queryHadError = false;
        if (searchSongs)
            _queryFetchQueue.push("songs");
        if (searchArtists)
            _queryFetchQueue.push("artists");
        if (searchAlbums)
            _queryFetchQueue.push("albums");
        _advanceQueryChain();
    }

    function _advanceQueryChain() {
        if (_desiredQuery !== _queryPending && _desiredQuery.length >= _minChars) {
            _beginQueryChain(_desiredQuery);
            return;
        }
        if (_queryFetchQueue.length === 0) {
            // Failed fetches are never cached, so the exact same query
            // retries automatically the next time it's submitted (typing
            // resumes, or the "MPD not connected" row is retried) instead of
            // permanently showing an empty result for that query string.
            if (_queryPending.length >= _minChars && !_queryHadError)
                _queryCachePut(_queryPending, _queryAccum);
            _notify();
            return;
        }

        const cat = _queryFetchQueue.shift();
        const q = _queryPending;
        let args;
        if (cat === "songs")
            args = _mpcArgv(["-f", _songFormat, "search", "any", q]);
        else if (cat === "artists")
            args = _mpcArgv(["-f", "%artist%", "search", "artist", q]);
        else
            args = _mpcArgv(["-f", _albumFormat, "search", "album", q]);

        queryWorker.run(args, (out, err, code) => {
            if (code === 0) {
                if (cat === "songs")
                    _queryAccum.songs = _parseSongLines(out).slice(0, maxPerCategory * 3);
                else if (cat === "artists")
                    _queryAccum.artists = _dedupeLines(out).slice(0, maxPerCategory * 3);
                else
                    _queryAccum.albums = _parseAlbumLines(out).slice(0, maxPerCategory * 3);
                _reportMpdOk();
            } else {
                _queryHadError = true;
                _reportMpdError(code, err);
            }
            _advanceQueryChain();
        });
    }

    function _queryCacheGet(q) {
        return Object.prototype.hasOwnProperty.call(_queryCache, q) ? _queryCache[q] : null;
    }

    function _queryCachePut(q, result) {
        const next = Object.assign({}, _queryCache);
        next[q] = result;
        const order = _queryCacheOrder.filter(k => k !== q);
        order.push(q);
        while (order.length > _queryCacheLimit)
            delete next[order.shift()];
        _queryCache = next;
        _queryCacheOrder = order;
    }

    // ------------------------------------------------------------- poll chain

    property var _plNames: []
    property bool _plNamesEverFetched: false
    property double _plNamesLastFetchAt: 0

    property var _plTracks: []
    property bool _plTracksEverFetched: false
    property double _plTracksLastFetchAt: 0
    property var _plTrackQueue: []
    property var _plTracksAccum: []

    function _maybePoll() {
        if (pollWorker.busy)
            return;
        const now = Date.now();
        const wantNames = searchPlaylists || searchPlaylistTracks;
        const wantTracks = searchPlaylistTracks;

        if (wantNames && (!_plNamesEverFetched || now - _plNamesLastFetchAt >= _namesIntervalMs)) {
            pollWorker.run(_mpcArgv(["lsplaylists"]), (out, err, code) => {
                _plNamesEverFetched = true;
                _plNamesLastFetchAt = Date.now();
                if (code === 0) {
                    _plNames = _dedupeLines(out);
                    _reportMpdOk();
                } else {
                    _reportMpdError(code, err);
                }
                _notify();
            });
            return;
        }

        if (wantTracks && _plNamesEverFetched && (!_plTracksEverFetched || now - _plTracksLastFetchAt >= _tracksIntervalMs)) {
            _plTrackQueue = _plNames.slice();
            _plTracksAccum = [];
            _advanceTrackQueue();
        }
    }

    function _advanceTrackQueue() {
        if (_plTrackQueue.length === 0) {
            _plTracks = _plTracksAccum;
            _plTracksAccum = [];
            _plTracksEverFetched = true;
            _plTracksLastFetchAt = Date.now();
            _notify();
            return;
        }

        const name = _plTrackQueue.shift();
        pollWorker.run(_mpcArgv(["-f", _trackFormat, "playlist", name]), (out, err, code) => {
            if (code === 0) {
                _plTracksAccum = _plTracksAccum.concat(_parseTrackLines(out, name));
                _reportMpdOk();
            } else {
                _reportMpdError(code, err);
            }
            _advanceTrackQueue();
        });
    }

    // A playlist can match two independent ways - its own name, or a track
    // inside it - so both routes are folded into one result per playlist
    // ("every list can be one row") rather than one row per matching track.
    // Selecting that row always acts on the playlist, never on a single track
    // inside it.
    function _matchPlaylists(q) {
        const lower = q.toLowerCase();
        const byName = {};

        if (searchPlaylists) {
            for (const n of _plNames) {
                if (n.toLowerCase().includes(lower))
                    byName[n] = { name: n, matchedTracks: [] };
            }
        }

        if (searchPlaylistTracks) {
            for (const t of _plTracks) {
                if (!t.title.toLowerCase().includes(lower) && !t.artist.toLowerCase().includes(lower))
                    continue;
                if (!byName[t.playlist])
                    byName[t.playlist] = { name: t.playlist, matchedTracks: [] };
                byName[t.playlist].matchedTracks.push(t.title);
            }
        }

        return Object.keys(byName).map(k => byName[k]).slice(0, maxPerCategory * 3);
    }

    function _playlistComment(e) {
        if (e.matchedTracks && e.matchedTracks.length > 0) {
            const shown = e.matchedTracks.slice(0, 3);
            const rest = e.matchedTracks.length - shown.length;
            return shown.join(" • ") + (rest > 0 ? " +" + rest + " more" : "");
        }
        const count = _plTracks.filter(t => t.playlist === e.name).length;
        return count > 0 ? (count + (count === 1 ? " track" : " tracks")) : "Playlist";
    }

    // ------------------------------------------------------------- workers
    //
    // Three independent workers so a stuck one never blocks the others: a
    // hung search shouldn't stop the playlist poll from refreshing, and an
    // in-flight action shouldn't wait behind either. Each is timeout-bounded
    // (see MpdWorker.qml) so an unreachable MPD host surfaces as a clean
    // failure instead of hanging forever.

    MpdWorker {
        id: queryWorker
    }

    MpdWorker {
        id: pollWorker
    }

    MpdWorker {
        id: actionWorker
    }

    // -------------------------------------------------------------- parsing

    function _firstErrorLine(text) {
        if (!text)
            return "";
        const lines = text.split("\n");
        for (const line of lines) {
            const trimmed = line.trim();
            if (trimmed.length > 0)
                return trimmed.length > 300 ? trimmed.substring(0, 300) + "…" : trimmed;
        }
        return "";
    }

    function _dedupeLines(text) {
        if (!text || text.trim().length === 0)
            return [];
        const seen = {};
        const out = [];
        for (const line of text.split("\n")) {
            const v = line.trim();
            if (v.length === 0 || seen[v])
                continue;
            seen[v] = true;
            out.push(v);
        }
        return out;
    }

    function _basename(file) {
        const slash = file.lastIndexOf("/");
        const name = slash >= 0 ? file.substring(slash + 1) : file;
        const dot = name.lastIndexOf(".");
        return dot > 0 ? name.substring(0, dot) : name;
    }

    function _parseSongLines(text) {
        if (!text || text.trim().length === 0)
            return [];
        const out = [];
        for (const line of text.split("\n")) {
            if (line.trim().length === 0)
                continue;
            const parts = line.split("\t");
            const file = parts[0] || "";
            out.push({
                file: file,
                artist: parts[1] || "",
                title: parts[2] || _basename(file),
                time: parts[3] || ""
            });
        }
        return out;
    }

    function _parseAlbumLines(text) {
        if (!text || text.trim().length === 0)
            return [];
        const seen = {};
        const out = [];
        for (const line of text.split("\n")) {
            if (line.trim().length === 0)
                continue;
            const parts = line.split("\t");
            const album = parts[0] || "";
            const albumArtist = parts[1] || "";
            const artist = parts[2] || "";
            const displayArtist = albumArtist || artist;
            const key = album + " " + displayArtist;
            if (album.length === 0 || seen[key])
                continue;
            seen[key] = true;
            out.push({
                name: album,
                artist: displayArtist
            });
        }
        return out;
    }

    function _parseTrackLines(text, playlistName) {
        if (!text || text.trim().length === 0)
            return [];
        const out = [];
        for (const line of text.split("\n")) {
            if (line.trim().length === 0)
                continue;
            const parts = line.split("\t");
            const file = parts[2] || "";
            out.push({
                playlist: playlistName,
                artist: parts[0] || "",
                title: parts[1] || _basename(file),
                file: file
            });
        }
        return out;
    }

    // ------------------------------------------------------------- ranking

    function _scoreText(text, lowerQuery) {
        const lower = (text || "").toLowerCase();
        if (lower === lowerQuery)
            return 300;
        if (lower.indexOf(lowerQuery) === 0)
            return 200;
        if (lower.indexOf(lowerQuery) >= 0)
            return 100 - Math.min(lower.length, 60);
        return 0;
    }

    // Category priority only breaks ties when text-match quality is equal;
    // it exists so "Kanye West" the artist doesn't get buried under twenty
    // equally-substring-matched track titles.
    readonly property var _kindPriority: ({ "song": 4, "playlist": 3, "artist": 2, "album": 1 })

    function _rankResults(results, q) {
        const lower = q.toLowerCase();
        const scored = results.map(r => {
            let score;
            if (r.kind === "song") {
                score = _scoreText(r.entry.title + " " + r.entry.artist, lower);
            } else if (r.kind === "playlist") {
                // A playlist that only matched via a track inside it should
                // rank by how good THAT match is, not by its own (possibly
                // unrelated) name.
                score = _scoreText(r.entry.name, lower);
                for (const t of (r.entry.matchedTracks || []))
                    score = Math.max(score, _scoreText(t, lower));
            } else {
                score = _scoreText(r.entry.name || "", lower);
            }
            return {
                r: r,
                score: score
            };
        });
        scored.sort((a, b) => {
            if (b.score !== a.score)
                return b.score - a.score;
            return _kindPriority[b.r.kind] - _kindPriority[a.r.kind];
        });
        return scored.map(e => e.r);
    }

    // --------------------------------------------------------------- items

    function _toItem(r, preScored) {
        const e = r.entry;
        if (r.kind === "song") {
            return {
                id: "mpd:song:" + e.file,
                name: e.title,
                icon: "material:music_note",
                comment: "Song · " + e.artist + (e.time ? " · " + e.time : ""),
                action: "primary",
                categories: ["MPD Songs"],
                _preScored: preScored,
                mpdKind: "song",
                mpdEntry: e
            };
        }
        if (r.kind === "playlist") {
            return {
                id: "mpd:playlist:" + e.name,
                name: e.name,
                icon: "material:queue_music",
                comment: _playlistComment(e),
                action: "primary",
                categories: ["MPD Playlists"],
                _preScored: preScored,
                mpdKind: "playlist",
                mpdEntry: e
            };
        }
        if (r.kind === "artist") {
            return {
                id: "mpd:artist:" + e.name,
                name: e.name,
                icon: "material:person",
                comment: "Artist",
                action: "primary",
                categories: ["MPD Artists"],
                _preScored: preScored,
                mpdKind: "artist",
                mpdEntry: e
            };
        }
        if (r.kind === "album") {
            return {
                id: "mpd:album:" + e.name + ":" + e.artist,
                name: e.name,
                icon: "material:album",
                comment: "Album" + (e.artist ? " · " + e.artist : ""),
                action: "primary",
                categories: ["MPD Albums"],
                _preScored: preScored,
                mpdKind: "album",
                mpdEntry: e
            };
        }
    }

    function _statusItem(icon, name, comment, action) {
        return {
            id: "mpd:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: action || "noop",
            categories: ["MPD"],
            _preScored: 10000
        };
    }

    // -------------------------------------------------------------- actions

    function _mpcPrefix() {
        const args = [];
        if (mpdHost.trim().length > 0)
            args.push("--host=" + mpdHost.trim());
        if (mpdPort.trim().length > 0)
            args.push("--port=" + mpdPort.trim());
        return args;
    }

    function _mpcArgv(subArgs) {
        return [mpcBin].concat(_mpcPrefix()).concat(subArgs);
    }

    function _shQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function _mpcCmdStr(subArgs) {
        return _mpcArgv(subArgs).map(_shQuote).join(" ");
    }

    function _runKindAction(item, actionId) {
        const kind = item.mpdKind;
        const e = item.mpdEntry;

        if (kind === "song") {
            if (actionId === "insertPlayNow") {
                _runChain(["insert", e.file], ["next"]);
                _toast("Playing next", e.title);
            } else if (actionId === "insertNext") {
                Quickshell.execDetached(_mpcArgv(["insert", e.file]));
                _toast("Added after current song", e.title);
            } else if (actionId === "replace") {
                _runChain(["clear"], ["add", e.file], ["play"]);
                _toast("Replaced queue", e.title);
            } else if (actionId === "enqueueEnd") {
                Quickshell.execDetached(_mpcArgv(["add", e.file]));
                _toast("Added to end of queue", e.title);
            }
            return;
        }

        if (kind === "playlist") {
            if (actionId === "replace") {
                _runChain(["clear"], ["load", e.name], ["play"]);
                _toast("Replaced queue", e.name);
            } else if (actionId === "enqueueEnd") {
                Quickshell.execDetached(_mpcArgv(["load", e.name]));
                _toast("Added to end of queue", e.name);
            } else if (actionId === "insertNext") {
                _resolvePlaylistFiles(e.name, files => root._insertFilesNext(files, e.name));
            }
            return;
        }

        if (kind === "artist") {
            const findArgs = ["findadd", "artist", e.name];
            if (actionId === "replace") {
                _runChain(["clear"], findArgs, ["play"]);
                _toast("Replaced queue", e.name);
            } else if (actionId === "enqueueEnd") {
                Quickshell.execDetached(_mpcArgv(findArgs));
                _toast("Added to end of queue", e.name);
            } else if (actionId === "insertNext") {
                _resolveArtistFiles(e.name, files => root._insertFilesNext(files, e.name));
            }
            return;
        }

        if (kind === "album") {
            const findArgs = ["findadd", "album", e.name];
            if (e.artist)
                findArgs.push("albumartist", e.artist);
            if (actionId === "replace") {
                _runChain(["clear"], findArgs, ["play"]);
                _toast("Replaced queue", e.name);
            } else if (actionId === "enqueueEnd") {
                Quickshell.execDetached(_mpcArgv(findArgs));
                _toast("Added to end of queue", e.name);
            } else if (actionId === "insertNext") {
                _resolveAlbumFiles(e.name, e.artist, files => root._insertFilesNext(files, e.name));
            }
        }
    }

    // mpc has no "insert this playlist/artist/album after current" primitive
    // - insert only takes file paths - so those three actions resolve the
    // matching file list first (via actionWorker, kept separate from the
    // search/poll workers so an action never waits behind an in-flight
    // search), then insert it as a block.
    function _resolvePlaylistFiles(name, cb) {
        if (actionWorker.busy) {
            root._toast("Still working…", "Wait for the previous action to finish first.");
            return;
        }
        actionWorker.run(_mpcArgv(["-f", "%file%", "playlist", name]), (out, err, code) => {
            if (code !== 0) {
                root._toastError("Could not read playlist", _firstErrorLine(err) || ("mpc exited with code " + code));
                return;
            }
            cb(_splitNonEmptyLines(out));
        });
    }

    function _resolveArtistFiles(name, cb) {
        if (actionWorker.busy) {
            root._toast("Still working…", "Wait for the previous action to finish first.");
            return;
        }
        actionWorker.run(_mpcArgv(["-f", "%file%", "search", "artist", name]), (out, err, code) => {
            if (code !== 0) {
                root._toastError("Could not look up songs", _firstErrorLine(err) || ("mpc exited with code " + code));
                return;
            }
            cb(_splitNonEmptyLines(out));
        });
    }

    function _resolveAlbumFiles(name, artist, cb) {
        if (actionWorker.busy) {
            root._toast("Still working…", "Wait for the previous action to finish first.");
            return;
        }
        const args = artist ? ["-f", "%file%", "search", "album", name, "albumartist", artist] : ["-f", "%file%", "search", "album", name];
        actionWorker.run(_mpcArgv(args), (out, err, code) => {
            if (code !== 0) {
                root._toastError("Could not look up songs", _firstErrorLine(err) || ("mpc exited with code " + code));
                return;
            }
            cb(_splitNonEmptyLines(out));
        });
    }

    function _insertFilesNext(files, label) {
        if (files.length === 0) {
            root._toastError("Nothing to add", "No matching tracks found for \"" + label + "\".");
            return;
        }
        const capped = files.slice(0, _maxInsertTracks);
        Quickshell.execDetached(["sh", "-c", _insertChainScript(capped)]);
        const countLabel = capped.length + (capped.length === 1 ? " track" : " tracks") + (files.length > capped.length ? " (of " + files.length + ")" : "");
        root._toast("Added after current song", countLabel + " from " + label);
    }

    // insert() places ONE file immediately after the current position, so
    // building an ordered block at current+1..current+N means inserting in
    // REVERSE - the last file goes in first (landing at current+1), then each
    // earlier file's insert pushes it one further back, ending in original
    // order. This holds regardless of whether mpc's own multi-argument
    // "insert a b c" batches order the same way, so it doesn't depend on that
    // being true.
    function _insertChainScript(files) {
        const reversed = files.slice().reverse();
        return reversed.map(f => _mpcCmdStr(["insert", f])).join(" && ");
    }

    function _splitNonEmptyLines(text) {
        if (!text || text.trim().length === 0)
            return [];
        return text.split("\n").map(l => l.trim()).filter(l => l.length > 0);
    }

    // Runs 2+ mpc invocations in guaranteed order (each waits for the previous
    // to exit) via a single shell script, rather than firing separate
    // execDetached calls whose relative arrival order at a remote MPD isn't
    // guaranteed.
    function _runChain(...steps) {
        const script = steps.map(s => _mpcCmdStr(s)).join(" && ");
        Quickshell.execDetached(["sh", "-c", script]);
    }

    function _toast(title, body) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, body);
    }

    function _toastError(title, body) {
        if (typeof ToastService !== "undefined" && typeof ToastService.showError === "function")
            ToastService.showError(title, body);
        else
            _toast(title, body);
    }

    function _notify() {
        itemsChanged();
        if (pluginService && typeof pluginService.requestLauncherUpdate === "function")
            pluginService.requestLauncherUpdate(pluginId);
    }
}
