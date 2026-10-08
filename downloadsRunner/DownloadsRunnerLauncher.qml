import QtQuick
import Quickshell
import qs.Common
import qs.Services
import "files.js" as Files

// Launcher provider for the downloads folder: `dl <words>` finds a file in it,
// newest first, and Enter puts the file's full path on the clipboard.
//
// getItems() has to answer synchronously, so the folder is listed in the
// background -- one find, a few milliseconds -- and the answer kept. A
// listing older than a few seconds is redone on the next keystroke, and the
// launcher is told when the new one lands, so a download that finished a
// moment ago is in the list by the time its name has been typed.
Item {
    id: root

    readonly property string pluginId: "downloadsRunner"

    property var pluginService: null
    property string trigger: "dl "

    signal itemsChanged

    // Settings, mirrored from plugin data (see DownloadsRunnerSettings.qml)
    property string folderSetting: ""
    property int depth: 3
    property int maxResults: 30
    property bool showHidden: false

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string folder: {
        let f = folderSetting.trim();
        if (f === "")
            f = home + "/Downloads";
        else if (f === "~" || f.startsWith("~/"))
            f = home + f.slice(1);
        return f.length > 1 ? f.replace(/\/+$/, "") : f;
    }
    // ~/Downloads rather than /home/you/Downloads, wherever a path is shown.
    readonly property string folderLabel: home && folder.startsWith(home + "/") ? "~" + folder.slice(home.length) : folder

    // The most a listing keeps, newest first. A downloads folder past this is
    // searched over its newest files only.
    readonly property int _maxEntries: 5000
    readonly property int _staleMs: 3000

    Component.onCompleted: _loadSettings()
    onPluginServiceChanged: _loadSettings()

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
        }
    }

    function _loadSettings() {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData(pluginId, "trigger", "dl ");
        folderSetting = pluginService.loadPluginData(pluginId, "folder", "") || "";
        depth = pluginService.loadPluginData(pluginId, "depth", 3);
        maxResults = pluginService.loadPluginData(pluginId, "maxResults", 30);
        showHidden = pluginService.loadPluginData(pluginId, "showHidden", false) === true;
        // A changed folder or depth makes the kept listing the wrong answer.
        _listedAt = 0;
    }

    // ---------------------------------------------------------------- launcher

    function getItems(query) {
        _maybeList();

        if (_error === "missing")
            return [_statusItem("folder_off", "No folder at " + folderLabel, "Choose the folder under Settings → Plugins → Downloads", "noop")];
        if (_error)
            return [_statusItem("error", "Could not list " + folderLabel, _error + "  ·  Press Enter to retry", "retry")];
        if (!_everListed)
            return [_statusItem("hourglass_empty", "Reading " + folderLabel + "…", "", "noop")];

        const q = (query || "").trim();
        const hits = Files.search(_entries, q, Math.max(1, maxResults));
        if (hits.length === 0)
            return [_statusItem("search_off", q ? "Nothing in " + folderLabel + " matches \"" + q + "\"" : folderLabel + " is empty", "", "noop")];

        const now = Date.now();
        return hits.map((e, i) => _toItem(e, now, 9000 - i));
    }

    function executeItem(item) {
        if (!item)
            return;
        if (item.action === "retry") {
            _error = "";
            _listedAt = 0;
            _maybeList();
            return;
        }
        if (item.fileEntry)
            _copyPath(item.fileEntry);
    }

    function getContextMenuActions(item) {
        if (!item || !item.fileEntry)
            return [];
        const e = item.fileEntry;
        return [
            {
                icon: "content_copy",
                text: "Copy path",
                action: () => root._copyPath(e)
            },
            {
                icon: "attach_file",
                text: e.isDir ? "Copy as a folder (paste into a file manager)" : "Copy as a file (paste into a chat or file manager)",
                action: () => root._copyAsFile(e)
            },
            {
                icon: "title",
                text: "Copy name",
                action: () => {
                    Quickshell.execDetached([Proc.dmsBin, "cl", "copy", e.name]);
                    root._toast("Name copied", e.name);
                }
            },
            {
                icon: "open_in_new",
                text: "Open",
                action: () => Quickshell.execDetached(["xdg-open", e.path])
            },
            {
                icon: "folder_open",
                text: "Show in folder",
                action: () => root._showInFolder(e)
            }
        ];
    }

    // ----------------------------------------------------------------- actions

    // Proc.dmsBin, not a bare "dms": the shell hands its children
    // $DMS_EXECUTABLE, but does not always have dms itself on PATH.
    function _copyPath(e) {
        Quickshell.execDetached([Proc.dmsBin, "cl", "copy", e.path]);
        _toast("Path copied", e.path);
    }

    // A file:// URI under text/uri-list is what a file manager pastes as the
    // file itself, and what a chat app takes as an attachment.
    function _copyAsFile(e) {
        Quickshell.execDetached(["sh", "-c", 'printf "%s\\r\\n" "$1" | "$2" cl copy --type text/uri-list', "sh", Files.fileUri(e.path), Proc.dmsBin]);
        _toast(e.isDir ? "Folder copied" : "File copied", e.name);
    }

    // The file manager's own D-Bus call opens the folder with the file
    // selected; without one, the folder is opened plainly.
    function _showInFolder(e) {
        const parent = e.path.slice(0, e.path.lastIndexOf("/")) || "/";
        Quickshell.execDetached(["sh", "-c", 'gdbus call --session --dest org.freedesktop.FileManager1 --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems "[\'$1\']" "" >/dev/null 2>&1 || xdg-open "$2"', "sh", Files.fileUri(e.path), parent]);
    }

    // ----------------------------------------------------------------- listing

    property var _entries: []
    property bool _everListed: false
    property double _listedAt: 0
    property string _listedFolder: ""
    property string _error: ""

    // Newest first, at most _maxEntries. Hidden files and folders are left out
    // unless asked for, and so is anything whose name holds a newline: one
    // record a line is the format, and such a name would come back as a
    // wrong path.
    readonly property string _listScript: 'd=$1; depth=$2; hidden=$3; max=$4
[ -d "$d" ] || exit 3
nl="*
*"
if [ "$hidden" = 1 ]; then
    find -L "$d" -mindepth 1 -maxdepth "$depth" -name "$nl" -prune -o -printf "%T@\\t%s\\t%y\\t%P\\n"
else
    find -L "$d" -mindepth 1 -maxdepth "$depth" \\( -name ".*" -o -name "$nl" \\) -prune -o -printf "%T@\\t%s\\t%y\\t%P\\n"
fi 2>/dev/null | sort -t "$(printf "\\t")" -k1,1nr | head -n "$max"'

    function _maybeList() {
        if (worker.busy)
            return;
        if (_everListed && _listedFolder === folder && (Date.now() - _listedAt) < _staleMs)
            return;

        const listed = folder;
        worker.run(["sh", "-c", _listScript, "downloads-list", listed, String(Math.max(1, depth)), showHidden ? "1" : "0", String(_maxEntries)], (out, err, code) => {
            _everListed = true;
            _listedAt = Date.now();
            _listedFolder = listed;
            if (code === 0) {
                _entries = Files.parseListing(out, listed);
                _error = "";
            } else if (code === 3) {
                _entries = [];
                _error = "missing";
            } else if (code === -1) {
                _error = "Listing took too long.";
            } else {
                _error = _firstErrorLine(err) || ("find exited with code " + code + ".");
            }
            _notify();
        });
    }

    function _firstErrorLine(text) {
        for (const line of (text || "").split("\n")) {
            const trimmed = line.trim();
            if (trimmed.length > 0)
                return trimmed.length > 300 ? trimmed.substring(0, 300) + "…" : trimmed;
        }
        return "";
    }

    ProcessWorker {
        id: worker
        timeoutMs: 8000
    }

    // ------------------------------------------------------------------- items

    function _toItem(e, now, preScored) {
        return {
            id: "dl:" + e.rel,
            name: e.name,
            icon: "material:" + Files.iconFor(e),
            comment: Files.describe(e, now),
            action: "copy",
            categories: ["Downloads"],
            keywords: [e.rel],
            primaryAction: {
                name: "Copy path",
                icon: "content_copy",
                action: "execute"
            },
            imagePath: Files.previewable(e) ? e.path : "",
            _preScored: preScored,
            fileEntry: e
        };
    }

    function _statusItem(icon, name, comment, action) {
        return {
            id: "dl:status",
            name: name,
            icon: "material:" + icon,
            comment: comment,
            action: action,
            categories: ["Downloads"],
            _preScored: 10000
        };
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
