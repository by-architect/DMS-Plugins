import QtQuick
import qs.Common

// Gates activation on the manager binary existing.
//
// The manager is Go and has to be compiled for the machine it runs on, so it is
// not shipped prebuilt. Without this the plugin would enable, the link would
// spawn a missing executable over and over, and the user would see an empty
// chat window with nothing explaining why.
QtObject {
    function check(done) {
        const dir = PluginService.getPluginPath("chatManager");
        if (!dir) {
            done({
                "title": "Chats plugin directory not found",
                "details": "The plugin could not locate its own files. Try reinstalling it."
            });
            return;
        }

        const manager = dir + "/bin/chat-managerd";

        Proc.runCommand("chatManager.managerCheck", ["test", "-x", manager], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": "Chat manager is not built",
                "details": "Run ./build.sh in " + dir + " to compile it (needs Go), then enable this plugin again."
            });
        });
    }
}
