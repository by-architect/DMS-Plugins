import QtQuick
import qs.Common

// Verifies both the ssh client and the configured terminal are reachable
// before the launcher trigger goes live - connecting silently does nothing
// useful if either is missing, so this turns that into an explanatory toast
// at enable time instead.
QtObject {
    function check(done) {
        const terminalBin = SettingsData.getPluginSetting("sshManager", "terminalBin", "ghostty");

        const script = 'command -v -- "$1" >/dev/null 2>&1 || { echo "missing:$1"; exit 1; }; ' + 'command -v -- "$2" >/dev/null 2>&1 || { echo "missing:$2"; exit 2; }';

        Proc.runCommand("sshManager.depCheck", ["sh", "-c", script, "sh", "ssh", terminalBin], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }

            const missing = (stdout || "").trim().replace(/^missing:/, "");
            if (exitCode === 1) {
                done({
                    "title": "ssh was not found",
                    "details": "'" + missing + "' is not on the shell's PATH. Install OpenSSH's client, then re-enable this plugin."
                });
                return;
            }
            done({
                "title": "Terminal was not found",
                "details": "'" + missing + "' is not on the shell's PATH. Set this plugin's Terminal setting to a terminal emulator you have installed, then re-enable it."
            });
        });
    }
}
