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

    // A notification was clicked: the manager asks for that conversation to be
    // shown, or for the window when the notification was about several.
    signal openRequested(string provider, string chatId)

    // Remembered so a failure inside a handler can name the call it came from.
    property string _lastMethod: ""
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
            root._pending[id] = {
                "callback": callback,
                "method": method
            };

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
            if (!event)
                return;
            if (event.service === "chat")
                root.chatStateUpdate(event.data);
            else if (event.service === "chat.open")
                root.openRequested(event.data?.provider ?? "", event.data?.chatId ?? "");
            return;
        }

        const pending = root._pending[msg.id];
        if (!pending)
            return;

        delete root._pending[msg.id];
        root._lastMethod = pending.method;
        pending.callback(msg);
    }

    Process {
        id: managerProcess

        // The socket is named rather than left to the manager's default, so
        // the two sides cannot disagree about where it is: without a runtime
        // directory each used to fall back to a different path in /tmp.
        command: [root._managerBinary, "-socket", root._socketPath]

        // The manager's log -- its own warnings, and why a bridge would not
        // start or keeps restarting -- written into the shell's, where
        // `quickshell log` shows it. Unread, Quickshell drops a child's output
        // on the floor, which left nothing at all to go on when chat did not
        // work. Debug lines only appear at DMS_CHAT_LOG_LEVEL=debug.
        stderr: SplitParser {
            onRead: line => {
                if (!line)
                    return;
                if (line.startsWith("WARN") || line.startsWith("ERROR"))
                    console.warn("chat-managerd:", line);
                else
                    console.log("chat-managerd:", line);
            }
        }

        onExited: exitCode => {
            root.managerRunning = false;
            if (exitCode !== 0)
                console.warn("chatManager: manager exited with", exitCode);
            // Deliberately not restarted from here. supervisor decides, and only
            // when nothing is answering the socket -- a manager that exited
            // because another one already holds the socket must not be
            // relaunched in a loop.
            supervisor.restart();
        }

        onStarted: {
            root.managerRunning = true;
            redial.start();
        }
    }

    // Dials the manager again while it is starting up.
    //
    // The socket's own retry backs off to fifteen seconds between attempts, and
    // by the time a manager is being started it has usually been failing for a
    // while -- so a manager that is listening within a second was not used for
    // up to fifteen, and chat sat unavailable after every restart. This asks
    // straight away and often, for the few seconds a start takes, then leaves
    // retrying to the socket again.
    Timer {
        id: redial

        property int attempts: 0

        interval: 250
        repeat: true
        onRunningChanged: {
            if (running)
                redial.attempts = 0;
        }
        onTriggered: {
            if (socket.linkUp || !managerProcess.running || ++redial.attempts > 40) {
                redial.stop();
                return;
            }
            socket.connected = false;
            socket.connected = true;
        }
    }

    // Starts the manager only when the socket is unanswered. Another shell, or
    // a manager left from a previous run, is served rather than fought over.
    Timer {
        id: supervisor

        interval: 2000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (socket.linkUp || managerProcess.running)
                return;
            managerProcess.running = true;
        }
    }

    DankSocket {
        id: socket

        path: root._socketPath
        connected: true

        parser: SplitParser {
            onRead: line => {
                if (!line)
                    return;

                // Parsing and handling are caught separately: wrapping both
                // reported a failure in some handler as an unreadable line,
                // which sent the last round of debugging the wrong way.
                let msg;
                try {
                    msg = JSON.parse(line);
                } catch (e) {
                    console.warn("chatManager: unreadable line from manager:", line.substring(0, 200));
                    return;
                }

                try {
                    root._handleMessage(msg);
                } catch (e) {
                    console.warn("chatManager: failed handling", root._lastMethod ? "the reply to " + root._lastMethod : "an event", "-", e);
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
                    pending[id].callback({
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
