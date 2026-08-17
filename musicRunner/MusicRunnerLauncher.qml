import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Launcher provider backed by `mpc`, MPD's command-line client. Searches up to
// five independently-toggleable categories at once (songs, playlists, artists,
// albums, and songs found inside playlists) and merges them into one ranked
// list.
//
// Two async subsystems run side by side:
//  - the query chain (songs/artists/albums): a fresh mpc search per category,
//    re-run whenever the typed query settles.
//  - the poll chain (playlists, and songs-inside-playlists): mpc search
//    doesn't cover saved-playlist contents, so those are fetched ahead of time
//    on a throttle and filtered locally, the same way tmuxRunner polls
//    `tmux list-sessions` instead of re-listing per keystroke.
// Both share the same "never block getItems()" contract: it always answers
// from cache immediately and kicks results in later via
// PluginService.requestLauncherUpdate().
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
    property string primaryAction: "enqueue"

    readonly property int _minChars: 2
    readonly property int _namesIntervalMs: 8000
    readonly property int _tracksIntervalMs: 30000
    readonly property string _songFormat: "%file%\t%artist%\t%title%\t%time%"
    readonly property string _albumFormat: "%album%\t%albumartist%\t%artist%"
    readonly property string _trackFormat: "%artist%\t%title%\t%file%"

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
        primaryAction = pluginService.loadPluginData(pluginId, "primaryAction", "enqueue");
    }

    // ---------------------------------------------------------------- launcher

    function getItems(query) {
        _maybePoll();

        const q = (query || "").trim();

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
        if (searchPlaylists)
            for (const p of _matchPlaylistNames(q))
                results.push({ kind: "playlist", entry: p });
        if (searchPlaylistTracks)
            for (const t of _matchPlaylistTracks(q))
                results.push({ kind: "track", entry: t });

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
        if (item.action === "noop")
            return;
        _runAction(item, primaryAction);
    }

    function getContextMenuActions(item) {
        if (!item || !item.mpdKind)
            return [];

        const actions = [];
        const label = item.mpdKind === "song" || item.mpdKind === "track" ? "song" : item.mpdKind === "playlist" ? "playlist" : item.mpdKind === "artist" ? "artist's songs" : "album's songs";

        actions.push({
            icon: "playlist_add",
            text: "Enqueue " + label,
            action: () => root._runAction(item, "enqueue")
        });
        actions.push({
            icon: "play_circle",
            text: "Play now",
            action: () => root._runAction(item, "playNow")
        });
        if (item.mpdKind === "song" || item.mpdKind === "track") {
            actions.push({
                icon: "playlist_play",
                text: "Play next",
                action: () => root._runAction(item, "playNext")
            });
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
                return names.map((n, i) => _toItem({ kind: "playlist", entry: { name: n } }, 9000 - i));
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
    property string _queryError: ""

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
            if (_queryPending.length >= _minChars)
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
                _queryError = "";
            } else {
                _queryError = _firstErrorLine(err) || ("mpc exited with code " + code);
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

    property string _plError: ""

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
                    _plError = "";
                } else {
                    _plError = _firstErrorLine(err) || ("mpc exited with code " + code);
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
            if (code === 0)
                _plTracksAccum = _plTracksAccum.concat(_parseTrackLines(out, name));
            _advanceTrackQueue();
        });
    }

    function _matchPlaylistNames(q) {
        const lower = q.toLowerCase();
        return _plNames.filter(n => n.toLowerCase().includes(lower)).slice(0, maxPerCategory * 3).map(n => ({ name: n }));
    }

    function _matchPlaylistTracks(q) {
        const lower = q.toLowerCase();
        return _plTracks.filter(t => t.title.toLowerCase().includes(lower) || t.artist.toLowerCase().includes(lower)).slice(0, maxPerCategory * 3);
    }

    // ------------------------------------------------------------- workers

    Process {
        id: queryWorker
        readonly property bool busy: running
        property var _onDone: null
        property string _stdout: ""
        property string _stderr: ""
        property bool _stdoutDone: false
        property bool _exitDone: false
        property int _exitCode: 0
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                queryWorker._stdout = text;
                queryWorker._stdoutDone = true;
                queryWorker._maybeDone();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: queryWorker._stderr = text
        }
        onExited: exitCode => {
            queryWorker._exitCode = exitCode;
            queryWorker._exitDone = true;
            queryWorker._maybeDone();
        }

        function run(args, onDone) {
            _onDone = onDone;
            command = args;
            running = true;
        }
        function _maybeDone() {
            if (!_stdoutDone || !_exitDone)
                return;
            const cb = _onDone, out = _stdout, err = _stderr, code = _exitCode;
            _onDone = null;
            _stdout = "";
            _stderr = "";
            _stdoutDone = false;
            _exitDone = false;
            _exitCode = 0;
            if (cb)
                cb(out, err, code);
        }
    }

    Process {
        id: pollWorker
        readonly property bool busy: running
        property var _onDone: null
        property string _stdout: ""
        property string _stderr: ""
        property bool _stdoutDone: false
        property bool _exitDone: false
        property int _exitCode: 0
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                pollWorker._stdout = text;
                pollWorker._stdoutDone = true;
                pollWorker._maybeDone();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: pollWorker._stderr = text
        }
        onExited: exitCode => {
            pollWorker._exitCode = exitCode;
            pollWorker._exitDone = true;
            pollWorker._maybeDone();
        }

        function run(args, onDone) {
            _onDone = onDone;
            command = args;
            running = true;
        }
        function _maybeDone() {
            if (!_stdoutDone || !_exitDone)
                return;
            const cb = _onDone, out = _stdout, err = _stderr, code = _exitCode;
            _onDone = null;
            _stdout = "";
            _stderr = "";
            _stdoutDone = false;
            _exitDone = false;
            _exitCode = 0;
            if (cb)
                cb(out, err, code);
        }
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
    readonly property var _kindPriority: ({ "song": 5, "playlist": 4, "artist": 3, "album": 2, "track": 1 })

    function _rankResults(results, q) {
        const lower = q.toLowerCase();
        const scored = results.map(r => {
            const text = r.kind === "song" ? (r.entry.title + " " + r.entry.artist) : r.kind === "track" ? (r.entry.title + " " + r.entry.artist) : (r.entry.name || "");
            return {
                r: r,
                score: _scoreText(text, lower)
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
                comment: "Playlist",
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
        // track
        return {
            id: "mpd:track:" + e.file,
            name: e.title,
            icon: "material:playlist_play",
            comment: "In: " + e.playlist + (e.artist ? " · " + e.artist : ""),
            action: "primary",
            categories: ["MPD Playlist Tracks"],
            _preScored: preScored,
            mpdKind: "track",
            mpdEntry: e
        };
    }

    function _statusItem(icon, name, comment) {
        return {
            id: "mpd:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: "noop",
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

    function _runAction(item, mode) {
        const kind = item.mpdKind;
        const e = item.mpdEntry;

        if (kind === "song" || kind === "track") {
            if (mode === "playNext") {
                Quickshell.execDetached(_mpcArgv(["insert", e.file]));
                _toast("Playing next", e.title);
            } else if (mode === "playNow") {
                _runChain(["clear"], ["add", e.file], ["play"]);
                _toast("Playing now", e.title);
            } else {
                Quickshell.execDetached(_mpcArgv(["add", e.file]));
                _toast("Enqueued", e.title);
            }
            return;
        }

        if (kind === "playlist") {
            if (mode === "playNow") {
                _runChain(["clear"], ["load", e.name], ["play"]);
                _toast("Playing now", e.name);
            } else {
                Quickshell.execDetached(_mpcArgv(["load", e.name]));
                _toast("Enqueued playlist", e.name);
            }
            return;
        }

        if (kind === "artist") {
            const findArgs = ["findadd", "artist", e.name];
            if (mode === "playNow") {
                _runChain(["clear"], findArgs, ["play"]);
                _toast("Playing now", e.name);
            } else {
                Quickshell.execDetached(_mpcArgv(findArgs));
                _toast("Enqueued " + e.name, "All matching songs");
            }
            return;
        }

        if (kind === "album") {
            const findArgs = ["findadd", "album", e.name];
            if (e.artist)
                findArgs.push("albumartist", e.artist);
            if (mode === "playNow") {
                _runChain(["clear"], findArgs, ["play"]);
                _toast("Playing now", e.name);
            } else {
                Quickshell.execDetached(_mpcArgv(findArgs));
                _toast("Enqueued " + e.name, "All tracks");
            }
        }
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

    function _notify() {
        itemsChanged();
        if (pluginService && typeof pluginService.requestLauncherUpdate === "function")
            pluginService.requestLauncherUpdate(pluginId);
    }
}
