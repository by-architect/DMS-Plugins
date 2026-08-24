import QtQuick
import qs.Common

// Gates activation on the two things this provider cannot work without.
//
// The bridge is Go and has to be compiled for the machine it runs on, so it is
// not shipped prebuilt. signal-cli is a separate program the bridge drives.
// Without this check the plugin would enable, the backend would fail to spawn
// or the bridge would fail to connect, and the user would see nothing but a
// provider stuck at "disconnected".
QtObject {
    function check(done) {
        const dir = PluginService.getPluginPath("signalChat");
        if (!dir) {
            done({
                "title": "Signal plugin directory not found",
                "details": "The plugin could not locate its own files. Try reinstalling it."
            });
            return;
        }

        const bridge = dir + "/bin/signal-chat-bridge";

        Proc.runCommand("signalChat.bridgeCheck", ["test", "-x", bridge], (stdout, exitCode) => {
            if (exitCode !== 0) {
                done({
                    "title": "Signal bridge is not built",
                    "details": "Run ./build.sh in " + dir + " to compile it (needs Go), then enable this plugin again."
                });
                return;
            }

            // Checked second so the message names whichever piece is actually
            // missing, rather than always blaming the build.
            Proc.runCommand("signalChat.cliCheck", ["sh", "-c", "command -v signal-cli"], (out, code) => {
                if (code === 0) {
                    done(null);
                    return;
                }
                done({
                    "title": "signal-cli is not installed",
                    "details": "This plugin reaches Signal through signal-cli. Install it from https://github.com/AsamK/signal-cli, make sure it is on your PATH, then enable this plugin again."
                });
            });
        });
    }
}
