import QtQuick
import qs.Common
import qs.Services

// Gates activation on the bridge binary existing.
//
// The bridge is Go and has to be compiled for the machine it runs on, so it is
// not shipped prebuilt. Without this the plugin would enable, the backend would
// fail to spawn a missing executable, and the user would see nothing but a
// provider stuck at "disconnected".
//
// qs.Services is imported for PluginService. The shell creates this object from
// inside PluginService, but a file only sees the singletons it imports itself:
// without the import the lookup threw, the shell counts a check that throws as
// passed, and the plugin enabled with no bridge to run -- exactly what this file
// exists to prevent.
//
// Deliberately does not check for a session: signing in happens in the chat
// window's sign-in panel once the plugin is on, so enabling without one is the
// normal first step rather than a misconfiguration.
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
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": "Matrix bridge is not built",
                "details": "Run ./build.sh in " + dir + " to compile it (needs Go), then enable this plugin again."
            });
        });
    }
}
