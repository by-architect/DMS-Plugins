import QtQuick
import qs.Common

// Only ssh itself is a hard requirement. The terminal is not checked here on
// purpose: Settings can't be opened until this check passes, so gating on a
// specific terminal (the "ghostty" default) would lock anyone without that
// terminal out of ever reaching the setting that lets them change it. A
// missing or wrong terminal is instead just a connect-time no-op -- see
// SSHManagerLauncher.qml.
QtObject {
    function check(done) {
        const script = 'command -v -- "$1" >/dev/null 2>&1 || { echo "missing:$1"; exit 1; }';

        Proc.runCommand("sshManager.depCheck", ["sh", "-c", script, "sh", "ssh"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }

            const missing = (stdout || "").trim().replace(/^missing:/, "");
            done({
                "title": "ssh was not found",
                "details": "'" + missing + "' is not on the shell's PATH. Install OpenSSH's client, then re-enable this plugin."
            });
        });
    }
}
