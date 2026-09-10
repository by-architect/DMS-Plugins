pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

// The link to the chat manager process.
//
// The chat backend used to live inside the DMS core daemon, reached through
// DMSService. Moving it into this plugin means the plugin now owns that
// process: it starts it, restarts it if it dies, and speaks the same JSON
// protocol to it over a socket of its own. Nothing about the wire format
// changed, which is why the provider bridges did not have to change either.
Item {
    id: root

    property string pluginDir: ""

    readonly property bool isConnected: socket.linkUp
    property bool managerRunning: false

    signal chatStateUpdate(var data)

    property bool _wantSubscription: false
    property int _nextRequestId: 1
    property var _pending: ({})

    readonly property string _socketPath: {
        const runtimeDir = Quickshell.env("XDG_RUNTIME_DIR");
        if (runtimeDir)
            return runtimeDir + "/dms-chat-manager.sock";
        return "/tmp/dms-chat-manager.sock";
    }

    readonly property string _managerBinary: {
        let dir = root.pluginDir;
        if (dir.startsWith("file://"))
            dir = dir.substring(7);
        if (dir.endsWith("/"))
            dir = dir.slice(0, -1);
        return dir + "/bin/chat-managerd";
    }

    // Subscribing is per connection, so the wish is remembered and reapplied
    // whenever the link comes back after a manager restart.
    function setSubscribed(wanted) {
        if (root._wantSubscription === wanted)
            return;

        root._wantSubscription = wanted;
        if (!socket.linkUp)
            return;

        sendRequest(wanted ? "subscribe" : "unsubscribe", {}, null);
    }

    function sendRequest(method, params, callback) {
        if (!socket.linkUp) {
            if (callback)
                callback({
                    "error": "the chat manager is not running"
                });
            return;
        }

        const id = root._nextRequestId++;
        if (callback)
            root._pending[id] = callback;

        socket.send(JSON.stringify({
            "id": id,
            "method": method,
            "params": params || {}
        }));
    }

    function _handleMessage(msg) {
        // A message with no id is a subscription event rather than a reply.
        if (msg.id === undefined || msg.id === 0) {
            const event = msg.result;
            if (event && event.service === "chat")
                root.chatStateUpdate(event.data);
            return;
        }

        const callback = root._pending[msg.id];
        if (!callback)
            return;

        delete root._pending[msg.id];
        callback(msg);
    }

    Process {
        id: managerProcess

        running: true
        command: [root._managerBinary]

        onExited: exitCode => {
            root.managerRunning = false;
            if (exitCode !== 0)
                console.warn("chatManager: manager exited with", exitCode, "- restarting");
            // Always comes back: the window is useless without it, and a
            // provider bridge left running by a crashed manager is reaped by
            // the new one on startup.
            restartTimer.restart();
        }

        onStarted: root.managerRunning = true
    }

    Timer {
        id: restartTimer

        interval: 2000
        onTriggered: managerProcess.running = true
    }

    DankSocket {
        id: socket

        path: root._socketPath
        connected: true

        parser: SplitParser {
            onRead: line => {
                if (!line)
                    return;
                try {
                    root._handleMessage(JSON.parse(line));
                } catch (e) {
                    console.warn("chatManager: unreadable line from manager:", e);
                }
            }
        }

        onConnectionStateChanged: {
            if (!socket.linkUp) {
                // Nothing will answer these now; failing them is kinder than
                // leaving callers waiting on a reply that cannot arrive.
                const pending = root._pending;
                root._pending = ({});
                for (const id in pending)
                    pending[id]({
                        "error": "lost the connection to the chat manager"
                    });
                return;
            }

            if (root._wantSubscription)
                socket.send(JSON.stringify({
                    "id": root._nextRequestId++,
                    "method": "subscribe",
                    "params": {}
                }));
        }
    }
}
