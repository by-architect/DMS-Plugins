import QtQuick
import qs.Common

// Verifies both configured binaries are present. kill is checked separately
// from ps because it's commonly a shell builtin too - this plugin calls it
// directly via argv (no shell), so only the standalone binary counts, and
// that distinction is exactly the kind of thing worth catching here rather
// than as a confusing "nothing happened" the first time someone tries to
// kill something.
QtObject {
    function check(done) {
        const psBin = SettingsData.getPluginSetting("processRunner", "psBin", "ps");
        const killBin = SettingsData.getPluginSetting("processRunner", "killBin", "kill");

        const script = 'command -v -- "$1" >/dev/null 2>&1 || { echo "missing:$1"; exit 1; }; ' + 'command -v -- "$2" >/dev/null 2>&1 || { echo "missing:$2"; exit 2; }';

        Proc.runCommand("processRunner.depCheck", ["sh", "-c", script, "sh", psBin, killBin], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }

            const missing = (stdout || "").trim().replace(/^missing:/, "");
            const which = exitCode === 1 ? "ps" : "kill";
            done({
                "title": "'" + which + "' was not found",
                "details": "'" + missing + "' is not on the shell's PATH. Install it, or set an absolute path under this plugin's settings, then re-enable it."
            });
        });
    }
}
