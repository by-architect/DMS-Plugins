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

        // kill can't go through `command -v` like ps does: that reports the
        // shell's own builtin, so a bare "kill" always passed - even with
        // nothing at all on PATH - and the one case this check is here for
        // went straight through. Instead PATH is walked for an actual
        // executable file (or an absolute path is tested directly).
        const script = 'command -v -- "$1" >/dev/null 2>&1 || { echo "missing:$1"; exit 1; }; ' + 'case "$2" in */*) [ -f "$2" ] && [ -x "$2" ] && exit 0 ;; ' + '*) set -f; IFS=:; for d in $PATH; do [ -f "$d/$2" ] && [ -x "$d/$2" ] && exit 0; done ;; esac; ' + 'echo "missing:$2"; exit 2';

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
