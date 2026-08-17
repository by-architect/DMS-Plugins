import QtQuick
import qs.Common

// Verifies both the tmux binary and the configured terminal are reachable
// before the launcher trigger goes live - attaching silently does nothing
// useful if either is missing, so this turns that into an explanatory toast
// at enable time instead.
QtObject {
    function check(done) {
        const tmuxBin = SettingsData.getPluginSetting("tmuxRunner", "tmuxBin", "tmux");
        const terminalBin = SettingsData.getPluginSetting("tmuxRunner", "terminalBin", "ghostty");

        const script = 'command -v -- "$1" >/dev/null 2>&1 || { echo "missing:$1"; exit 1; }; ' + 'command -v -- "$2" >/dev/null 2>&1 || { echo "missing:$2"; exit 2; }';

        Proc.runCommand("tmuxRunner.depCheck", ["sh", "-c", script, "sh", tmuxBin, terminalBin], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }

            const missing = (stdout || "").trim().replace(/^missing:/, "");
            if (exitCode === 1) {
                done({
                    "title": "tmux was not found",
                    "details": "'" + missing + "' is not on the shell's PATH. Install tmux, or set an absolute path under this plugin's settings, then re-enable it."
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
