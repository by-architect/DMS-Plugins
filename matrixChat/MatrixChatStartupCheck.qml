import QtQuick
import qs.Common

// Gates activation on the two things this provider cannot work without: a built
// bridge, and a session to resume.
//
// The session check matters more here than for other providers. Matrix has no
// QR code to scan, so signing in happens in a terminal via ./login.sh. Without
// this the plugin would enable, sit at "needsLogin" with a sign-in panel that
// has nothing to show, and give no hint that the answer is a shell script.
QtObject {
    function check(done) {
        const dir = PluginService.getPluginPath("matrixChat");
        if (!dir) {
            done({
                "title": "Matrix plugin directory not found",
                "details": "The plugin could not locate its own files. Try reinstalling it."
            });
            return;
        }

        const bridge = dir + "/bin/matrix-chat-bridge";

        Proc.runCommand("matrixChat.bridgeCheck", ["test", "-x", bridge], (stdout, exitCode) => {
            if (exitCode !== 0) {
                done({
                    "title": "Matrix bridge is not built",
                    "details": "Run ./build.sh in " + dir + " to compile it (needs Go), then enable this plugin again."
                });
                return;
            }

            // Checked second so the message names whichever step is actually
            // outstanding, rather than always blaming the build.
            const session = "${XDG_DATA_HOME:-$HOME/.local/share}/dms-matrix/session.json";

            Proc.runCommand("matrixChat.sessionCheck", ["sh", "-c", "test -f " + session], (out, code) => {
                if (code === 0) {
                    done(null);
                    return;
                }
                done({
                    "title": "Not signed in to Matrix",
                    "details": "Run ./login.sh in " + dir + " to sign in. It asks for your homeserver, user id and password, keeps only the resulting token, and never stores the password."
                });
            });
        });
    }
}
