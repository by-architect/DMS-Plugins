import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

// Headless hub for a list of SSH connections. Other plugins reach this
// through pluginService.pluginDaemonInstances["sshManager"] -- the same
// pattern chatManager uses for its providers -- to read the host list or
// build a ready ssh invocation, without knowing anything about how or where
// it's configured.
//
// Host metadata (name, host, port, username, auth method, identity file)
// lives in this plugin's ordinary settings, alongside every other plugin's
// config, in ~/.config/DankMaterialShell/plugin_settings.json. Stored
// passwords do not: they go in their own file under
// ~/.local/share/DankMaterialShell/plugins/sshManager/secrets.json, mode
// 0600, so a stray `cat plugin_settings.json` -- or a dotfiles repo it ends
// up in -- never dumps a password next to a hundred other plugins' settings.
//
// That file is still plaintext, readable by this user account, same as
// commandRunner's shell commands or systemPanel's login history -- there is
// no sandbox between plugins here. Prefer key-based auth (the default) and
// only store a password for hosts where that's genuinely not an option.
Item {
    id: root

    readonly property string pluginId: "sshManager"
    property var pluginService: null

    // No explicit "signal hostsChanged" here -- `property var hosts` already
    // auto-generates one, and redeclaring it is a hard QML error ("Duplicate
    // signal name") that fails this whole component to load.
    property var hosts: []

    readonly property string _secretsDir: Paths.strip(Paths.data) + "/plugins/sshManager"
    readonly property string _secretsPath: root._secretsDir + "/secrets.json"
    property var _secrets: ({})
    property bool _secretsLoaded: false
    property var _secretsWriter: null

    Component.onCompleted: {
        _loadHosts();
        _loadSecrets();
    }

    onPluginServiceChanged: _loadHosts()

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId !== root.pluginId)
                return;
            root._loadHosts();
        }
    }

    // ----------------------------------------------------------------- hosts

    function _loadHosts() {
        if (!pluginService)
            return;
        const loaded = pluginService.loadPluginData(pluginId, "hosts", []);
        hosts = Array.isArray(loaded) ? loaded : [];
    }

    function _saveHosts(newHosts) {
        hosts = newHosts;
        if (pluginService)
            pluginService.savePluginData(pluginId, "hosts", newHosts);
    }

    // ---------------------------------------------------------------- CRUD

    function addHost(entry) {
        const id = "h" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
        _saveHosts(hosts.concat([_sanitize(Object.assign({}, entry, {
            id: id
        }))]));
        return id;
    }

    function updateHost(hostId, entry) {
        const idx = hosts.findIndex(h => h.id === hostId);
        if (idx === -1)
            return;
        const updated = hosts.slice();
        updated[idx] = _sanitize(Object.assign({}, updated[idx], entry, {
            id: hostId
        }));
        _saveHosts(updated);
    }

    function removeHost(hostId) {
        _saveHosts(hosts.filter(h => h.id !== hostId));
        clearPassword(hostId);
    }

    function _sanitize(entry) {
        return {
            id: entry.id,
            name: (entry.name || "").trim(),
            host: (entry.host || "").trim(),
            port: (entry.port || "22").toString().trim() || "22",
            username: (entry.username || "").trim(),
            authMethod: entry.authMethod === "password" ? "password" : "key",
            identityFile: (entry.identityFile || "").trim(),
            hasPassword: !!entry.hasPassword
        };
    }

    // -------------------------------------------------------------- secrets

    Component {
        id: _secretsFvComp
        FileView {
            blockLoading: true
            blockWrites: true
            atomicWrites: true
        }
    }

    function _loadSecrets() {
        Paths.mkdir(root._secretsDir);
        try {
            const fv = _secretsFvComp.createObject(root, {
                path: root._secretsPath
            });
            const raw = fv.text();
            root._secrets = raw && raw.trim() ? JSON.parse(raw) : {};
            root._secretsWriter = fv;
        } catch (e) {
            root._secrets = {};
        }
        root._secretsLoaded = true;
    }

    function _writeSecrets() {
        const content = JSON.stringify(root._secrets, null, 2);
        if (!root._secretsWriter) {
            Paths.mkdir(root._secretsDir);
            root._secretsWriter = _secretsFvComp.createObject(root, {
                path: root._secretsPath
            });
        }
        root._secretsWriter.setText(content);
        Quickshell.execDetached(["chmod", "600", root._secretsPath]);
    }

    function hasPassword(hostId) {
        return !!root._secrets[hostId];
    }

    // Deliberately available to any other plugin holding this instance --
    // the same trust boundary commandRunner already runs your commands
    // under. A runner that needs to authenticate non-interactively should
    // pass this through a Process' `environment` (e.g. `sshpass -e`), never
    // as a command-line argument, so it doesn't end up in `ps` output.
    function getPassword(hostId) {
        return root._secrets[hostId] || "";
    }

    function setPassword(hostId, password) {
        const updated = Object.assign({}, root._secrets);
        if (password) {
            updated[hostId] = password;
        } else {
            delete updated[hostId];
        }
        root._secrets = updated;
        _writeSecrets();
        _setHasPasswordFlag(hostId, !!password);
    }

    function clearPassword(hostId) {
        setPassword(hostId, "");
    }

    function _setHasPasswordFlag(hostId, has) {
        const idx = hosts.findIndex(h => h.id === hostId);
        if (idx === -1 || hosts[idx].hasPassword === has)
            return;
        const updated = hosts.slice();
        updated[idx] = Object.assign({}, updated[idx], {
            hasPassword: has
        });
        _saveHosts(updated);
    }

    // ------------------------------------------------------- consumer API

    function getHosts() {
        return hosts.map(h => Object.assign({}, h));
    }

    function getHost(hostId) {
        const h = hosts.find(h => h.id === hostId);
        return h ? Object.assign({}, h) : null;
    }

    function findHostByName(name) {
        const h = hosts.find(h => h.name === name);
        return h ? Object.assign({}, h) : null;
    }

    // Builds a ready argv: ["ssh", "-p", "2222", "-i", "/home/x/.ssh/id", "user@host"].
    // Password auth is deliberately left out of argv -- ssh prompts for it
    // interactively when run in a terminal. A caller driving this
    // non-interactively should read getPassword() itself and feed it to
    // `sshpass -e` (or equivalent) through a Process' `environment`.
    function buildSshArgs(hostId) {
        const h = getHost(hostId);
        if (!h || !h.host)
            return null;
        const argv = ["ssh"];
        if (h.port && h.port !== "22")
            argv.push("-p", h.port);
        if (h.authMethod === "key" && h.identityFile)
            argv.push("-i", Paths.expandTilde(h.identityFile));
        argv.push(h.username ? (h.username + "@" + h.host) : h.host);
        return argv;
    }
}
