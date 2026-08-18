import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Launcher provider backed by `mpc`, MPD's command-line client. Searches up to
// six independently-toggleable categories at once (songs, playlists, artists,
// albums, songs found inside playlists, and the current playback queue) and
// merges them into one ranked list. A query can be scoped to just one
// category with a short prefix - see _parseScope/_scopeAliases - e.g.
// "mpd l rap" searches only Lists.
//
// A playlist is one row no matter how it matched - by its own name, or by a
// track found inside it - since the result-row layout is a single elided
// line (no real multi-line rows, and no per-item icon color, exist anywhere
// in this launcher - both checked directly against ResultItem.qml /
// AppIconRenderer.qml). "List name, then each matching track on its own line
// underneath" is built from several single-line rows: a header (acts on the
// whole playlist) followed by one label row per matching track (visible,
// not independently selectable - there's no way to make an individual row
// skip keyboard navigation here, only a whole section can).
//
// Three async subsystems run side by side, each with its own Process so none
// waits behind another:
//  - the query chain (songs/artists/albums): a fresh mpc search per category,
//    re-run whenever the typed query settles.
//  - the poll chain (playlists, songs-inside-playlists, and the current
//    queue): mpc search doesn't cover saved-playlist contents or the queue,
//    so those are fetched ahead of time on a throttle and filtered locally,
//    the same way tmuxRunner polls `tmux list-sessions` instead of
//    re-listing per keystroke.
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
    property bool searchNowPlaying: true
    property int maxPerCategory: 6

    readonly property int _minChars: 2
    readonly property int _namesIntervalMs: 8000
    readonly property int _tracksIntervalMs: 30000
    readonly property int _maxInsertTracks: 30
    readonly property string _songFormat: "%file%\t%artist%\t%title%\t%time%"
    readonly property string _albumFormat: "%album%\t%albumartist%\t%artist%"
    readonly property string _trackFormat: "%artist%\t%title%\t%file%"

    // One global action list, shared by every kind except "queue" (which only
    // ever means "jump to it" - see _queueActions). Enter runs the first
    // action; right-click exposes all of them in this order. "Replace queue
    // and play" is deliberately first: pushing a song/list/artist/album
    // starts listening to just that, the way most music apps treat clicking
    // an album as "play this now".
    readonly property var _groupActions: [
        { id: "replace", icon: "restart_alt", label: "Replace queue and play" },
        { id: "enqueueEnd", icon: "playlist_add", label: "Add to end of queue" },
        { id: "insertNext", icon: "playlist_play", label: "Add after current song" }
    ]
    readonly property var _queueActions: [
        { id: "jumpTo", icon: "play_circle", label: "Play this song now" }
    ]

    function _actionsForKind(kind) {
        return kind === "queue" ? _queueActions : _groupActions;
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
            root._queueEverFetched = false;
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
        searchNowPlaying = pluginService.loadPluginData(pluginId, "searchNowPlaying", true);
        maxPerCategory = pluginService.loadPluginData(pluginId, "maxPerCategory", 6);
    }

    // ---------------------------------------------------------------- launcher

    // A query can be scoped to one category by starting it with a short
    // prefix and a space, e.g. "mpd l rap" searches only Lists. Overrides
    // whatever's enabled in settings for that one query - useful to reach a
    // category you've turned off without going into settings for it.
    readonly property var _scopeAliases: ({
        "s": "songs", "song": "songs", "songs": "songs", "music": "songs", "musics": "songs",
        "l": "lists", "list": "lists", "lists": "lists", "playlist": "lists", "playlists": "lists",
        "ar": "artists", "artist": "artists", "artists": "artists",
        "al": "albums", "album": "albums", "albums": "albums",
        "q": "queue", "queue": "queue", "now": "queue", "nowplaying": "queue", "playing": "queue"
    })

    function _parseScope(text) {
        const m = text.match(/^(\S+)\s+([\s\S]*)$/);
        if (!m)
            return null;
        const scope = _scopeAliases[m[1].toLowerCase()];
        if (!scope)
            return null;
        return { scope: scope, rest: m[2] };
    }

    function getItems(query) {
        _maybePoll();

        const raw = (query || "").trim();

        // Shown immediately, regardless of query length, so opening the
        // trigger while MPD is down says so up front instead of just
        // returning nothing or "Searching...". Clears itself the moment any
        // subsystem's next attempt succeeds - no action needed once MPD
        // comes back, though "Press Enter to retry" forces an immediate
        // attempt instead of waiting for the next scheduled poll.
        if (_mpdError)
            return [_statusItem("cloud_off", "MPD not connected", _mpdError + "  ·  Press Enter to retry", "retryConnection")];

        const parsed = _parseScope(raw);
        const scope = parsed ? parsed.scope : "all";
        const q = (parsed ? parsed.rest : raw).trim();

        const activeSongs = scope === "all" ? searchSongs : scope === "songs";
        const activeArtists = scope === "all" ? searchArtists : scope === "artists";
        const activeAlbums = scope === "all" ? searchAlbums : scope === "albums";
        const activeLists = scope === "all" ? (searchPlaylists || searchPlaylistTracks) : scope === "lists";
        const activeQueue = scope === "all" ? searchNowPlaying : scope === "queue";

        if (q.length === 0)
            return _emptyQueryItems(scope, activeLists, activeQueue);

        if (q.length < _minChars)
            return [_statusItem("keyboard", "Keep typing…", "At least " + _minChars + " characters needed")];

        if (activeSongs || activeArtists || activeAlbums)
            _maybeStartQuery(scope, q);

        // Each match is a "group" of 1+ rows that must stay together and
        // move as a unit when sorted by relevance - a matching playlist is a
        // header row plus one label row per matching track underneath it
        // (see _playlistGroup), everything else is a single-row group.
        // Result rows have no real multi-line layout in this launcher (see
        // ResultItem.qml - every row is a single elided line, for every
        // plugin), so "list name, tracks indented underneath" is built from
        // several single-line rows instead of one row spanning several
        // lines.
        const groups = [];
        const cached = _queryCacheGet(scope + " " + q);
        const lower = q.toLowerCase();

        if (activeSongs && cached)
            for (const s of cached.songs)
                groups.push({ score: _scoreText(s.title + " " + s.artist, lower), kind: "song", rows: [_toItem({ kind: "song", entry: s }, 0)] });
        if (activeArtists && cached)
            for (const a of cached.artists)
                groups.push({ score: _scoreText(a, lower), kind: "artist", rows: [_toItem({ kind: "artist", entry: { name: a } }, 0)] });
        if (activeAlbums && cached)
            for (const a of cached.albums)
                groups.push({ score: _scoreText(a.name || "", lower), kind: "album", rows: [_toItem({ kind: "album", entry: a }, 0)] });
        if (activeLists)
            for (const p of _matchPlaylists(q, scope === "lists"))
                groups.push(_playlistGroup(p, lower));
        if (activeQueue)
            for (const t of _matchQueue(q))
                groups.push({ score: _scoreText(t.title + " " + t.artist, lower), kind: "queue", rows: [_toItem({ kind: "queue", entry: t }, 0)] });

        groups.sort((a, b) => {
            if (b.score !== a.score)
                return b.score - a.score;
            return _kindPriority[b.kind] - _kindPriority[a.kind];
        });

        const items = [];
        const maxRows = 40;
        for (const g of groups) {
            if (items.length + g.rows.length > maxRows)
                break;
            for (const row of g.rows)
                items.push(row);
        }
        for (let i = 0; i < items.length; i++)
            items[i]._preScored = 9000 - i;

        if (items.length === 0) {
            const stillWaiting = (activeSongs || activeArtists || activeAlbums) && !cached;
            if (stillWaiting)
                return [_statusItem("hourglass_empty", "Searching MPD…", "")];
            return [_statusItem("search_off", "No matches for \"" + q + "\"", "")];
        }

        return items;
    }

    function executeItem(item) {
        if (!item)
            return;

        if (item.action === "retryConnection") {
            // Reset the poll throttle so this doesn't just wait out the
            // normal 8s/30s cycle, then immediately retry whatever's
            // relevant: the playlist/queue poll, and the active query if
            // there is one.
            _plNamesLastFetchAt = 0;
            _plTracksLastFetchAt = 0;
            _queueLastFetchAt = 0;
            _maybePoll();
            if (_desiredText.length >= _minChars)
                _maybeStartQuery(_desiredScope, _desiredText, true);
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

        if (item.mpdKind === "song" || item.mpdKind === "queue") {
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

    function _emptyQueryItems(scope, activeLists, activeQueue) {
        if (activeLists) {
            const items = _browseListsItems();
            if (items.length > 0)
                return items;
        }
        if (activeQueue) {
            const items = _browseQueueItems();
            if (items.length > 0)
                return items;
        }
        if (scope !== "all")
            return [_statusItem("keyboard", "Type something to search " + scope, "")];
        return [_statusItem("search", "Search your MPD library", "Type a song, playlist, artist or album name")];
    }

    function _browseListsItems() {
        const names = _plNames.slice(0, Math.max(1, maxPerCategory) * 2);
        return names.map((n, i) => _toItem({ kind: "playlist", entry: { name: n, matchedTracks: [] } }, 9000 - i));
    }

    function _browseQueueItems() {
        const shown = _queueTracks.slice(0, Math.max(1, maxPerCategory) * 2);
        return shown.map((t, i) => _toItem({ kind: "queue", entry: t }, 9000 - i));
    }

    // ------------------------------------------------------------ query chain

    property var _queryCache: ({})
    property var _queryCacheOrder: []
    readonly property int _queryCacheLimit: 30

    // "Desired" is what getItems() most recently asked for; "pending" is
    // what's actually in flight. A scoped query ("mpd s kanye") and an
    // unscoped one ("mpd kanye") must be tracked and cached separately, since
    // they can search different categories for the same text - both halves
    // (scope, text) are compared, not just the text.
    property string _desiredScope: "all"
    property string _desiredText: ""
    property string _queryPendingScope: "all"
    property string _queryPendingText: ""
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
        onTriggered: root._maybeStartQuery(root._desiredScope, root._desiredText, true)
    }

    function _maybeStartQuery(scope, text, settled) {
        if (_queryCacheGet(scope + " " + text))
            return;
        if (!settled) {
            _desiredScope = scope;
            _desiredText = text;
            queryDebounce.restart();
            return;
        }
        _desiredScope = scope;
        _desiredText = text;
        if (queryWorker.busy)
            return;
        _beginQueryChain(scope, text);
    }

    function _beginQueryChain(scope, text) {
        _queryPendingScope = scope;
        _queryPendingText = text;
        _queryAccum = { songs: [], artists: [], albums: [] };
        _queryFetchQueue = [];
        _queryHadError = false;
        const wantSongs = scope === "all" ? searchSongs : scope === "songs";
        const wantArtists = scope === "all" ? searchArtists : scope === "artists";
        const wantAlbums = scope === "all" ? searchAlbums : scope === "albums";
        if (wantSongs)
            _queryFetchQueue.push("songs");
        if (wantArtists)
            _queryFetchQueue.push("artists");
        if (wantAlbums)
            _queryFetchQueue.push("albums");
        _advanceQueryChain();
    }

    function _advanceQueryChain() {
        if ((_desiredScope !== _queryPendingScope || _desiredText !== _queryPendingText) && _desiredText.length >= _minChars) {
            _beginQueryChain(_desiredScope, _desiredText);
            return;
        }
        if (_queryFetchQueue.length === 0) {
            // Failed fetches are never cached, so the exact same query
            // retries automatically the next time it's submitted (typing
            // resumes, or the "MPD not connected" row is retried) instead of
            // permanently showing an empty result for that query string.
            if (_queryPendingText.length >= _minChars && !_queryHadError)
                _queryCachePut(_queryPendingScope + " " + _queryPendingText, _queryAccum);
            _notify();
            return;
        }

        const cat = _queryFetchQueue.shift();
        const q = _queryPendingText;
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

    // Keyed by "scope text" (e.g. "songs kanye" vs "all kanye") so a scoped
    // query and an unscoped one for the same text don't collide - they can
    // search different categories.
    function _queryCacheGet(key) {
        return Object.prototype.hasOwnProperty.call(_queryCache, key) ? _queryCache[key] : null;
    }

    function _queryCachePut(key, result) {
        const next = Object.assign({}, _queryCache);
        next[key] = result;
        const order = _queryCacheOrder.filter(k => k !== key);
        order.push(key);
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

    property var _queueTracks: []
    property bool _queueEverFetched: false
    property double _queueLastFetchAt: 0

    function _maybePoll() {
        if (pollWorker.busy)
            return;
        const now = Date.now();
        const wantNames = searchPlaylists || searchPlaylistTracks;
        const wantTracks = searchPlaylistTracks;
        const wantQueue = searchNowPlaying;

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
            return;
        }

        if (wantQueue && (!_queueEverFetched || now - _queueLastFetchAt >= _namesIntervalMs)) {
            // No %position% here - combining it with other tag fields in one
            // -f format string returns bare position numbers only, silently
            // dropping every other field (reproduced live against the real
            // server). Position is just the 1-based line number instead,
            // which `mpc playlist` (bare, no name = the current queue, not a
            // saved playlist) already guarantees is in queue order.
            pollWorker.run(_mpcArgv(["-f", _songFormat, "playlist"]), (out, err, code) => {
                _queueEverFetched = true;
                _queueLastFetchAt = Date.now();
                if (code === 0) {
                    _queueTracks = _parseQueueLines(out);
                    _reportMpdOk();
                } else {
                    _reportMpdError(code, err);
                }
                _notify();
            });
        }
    }

    function _parseQueueLines(text) {
        return _parseSongLines(text).map((s, i) => ({
            position: i + 1,
            file: s.file,
            artist: s.artist,
            title: s.title,
            time: s.time
        }));
    }

    function _matchQueue(q) {
        const lower = q.toLowerCase();
        return _queueTracks.filter(t => t.title.toLowerCase().includes(lower) || t.artist.toLowerCase().includes(lower)).slice(0, maxPerCategory * 3);
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
    // forceAll is set when a query is explicitly scoped to lists ("mpd l
    // ..."), which searches both name and track matches regardless of
    // whether the two are individually enabled in settings - an explicit
    // scope request overrides the per-category toggles for that one query.
    function _matchPlaylists(q, forceAll) {
        const lower = q.toLowerCase();
        const byName = {};

        if (forceAll || searchPlaylists) {
            for (const n of _plNames) {
                if (n.toLowerCase().includes(lower))
                    byName[n] = { name: n, matchedTracks: [] };
            }
        }

        if (forceAll || searchPlaylistTracks) {
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

    // The header row's own subtitle. When the match came from tracks inside
    // the playlist, those tracks get their own label rows right below (see
    // _playlistGroup) instead of being summarized here too.
    function _playlistHeaderComment(e) {
        if (e.matchedTracks && e.matchedTracks.length > 0)
            return e.matchedTracks.length + (e.matchedTracks.length === 1 ? " matching track" : " matching tracks");
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

    // Category priority only breaks ties when text-match quality is equal.
    // Order: queue (already loaded, most directly actionable) > lists >
    // albums > artists > songs.
    readonly property var _kindPriority: ({ "queue": 5, "playlist": 4, "album": 3, "artist": 2, "song": 1 })

    // A playlist match becomes a header row (acts on the whole playlist,
    // per "you run the list, not the music") followed by one label row per
    // matching track underneath it - visible, but not independently
    // selectable, since there's no way to make individual rows skip keyboard
    // navigation in this launcher (only whole section headers can do that,
    // and this plugin only has the one section). The whole group is scored
    // by its best-matching row so it moves together under ranking, rather
    // than the header and its children scattering to wherever their
    // individual scores would place them.
    readonly property int _maxTrackLabelsPerPlaylist: 5

    function _playlistGroup(e, lower) {
        let score = _scoreText(e.name, lower);
        for (const t of (e.matchedTracks || []))
            score = Math.max(score, _scoreText(t, lower));

        const rows = [_toItem({ kind: "playlist", entry: e }, 0)];
        if (e.matchedTracks && e.matchedTracks.length > 0) {
            const shown = e.matchedTracks.slice(0, _maxTrackLabelsPerPlaylist);
            for (let i = 0; i < shown.length; i++)
                rows.push(_trackLabelItem(e.name, shown[i], i));
            const rest = e.matchedTracks.length - shown.length;
            if (rest > 0)
                rows.push(_moreLabelItem(e.name, rest));
        }

        return { score: score, kind: "playlist", rows: rows };
    }

    // Leading spaces are the only "tab" available - a plain Text element has
    // no per-row indent/margin control exposed to a plugin, so the indent is
    // baked into the name string itself. Widened from the original 3 spaces
    // to read more clearly as nested under the header above it.
    readonly property string _trackLabelIndent: "        "

    function _trackLabelItem(playlistName, title, index) {
        return {
            id: "mpd:tracklabel:" + playlistName + ":" + index,
            name: _trackLabelIndent + "- " + title,
            icon: "material:music_note",
            comment: "",
            action: "noop",
            categories: ["MPD Playlist Tracks"]
        };
    }

    function _moreLabelItem(playlistName, restCount) {
        return {
            id: "mpd:tracklabel:" + playlistName + ":more",
            name: _trackLabelIndent + "+" + restCount + (restCount === 1 ? " more track" : " more tracks"),
            icon: "material:more_horiz",
            comment: "",
            action: "noop",
            categories: ["MPD Playlist Tracks"]
        };
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
                comment: _playlistHeaderComment(e),
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
        if (r.kind === "queue") {
            return {
                id: "mpd:queue:" + e.position,
                name: e.title,
                icon: "material:queue_music",
                comment: "Now playing queue · #" + e.position + (e.artist ? " · " + e.artist : ""),
                action: "primary",
                categories: ["MPD Now Playing"],
                _preScored: preScored,
                mpdKind: "queue",
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
            if (actionId === "insertNext") {
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

        if (kind === "queue") {
            if (actionId === "jumpTo") {
                Quickshell.execDetached(_mpcArgv(["play", String(e.position)]));
                _toast("Playing", e.title);
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
