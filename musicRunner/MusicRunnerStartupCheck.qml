import QtQuick
import qs.Common

// Verifies the mpc binary is present, then that MPD is actually reachable.
// Both matter here: unlike a local tool, MPD_HOST can point at a remote host
// (as it does on this machine, over Tailscale), and connecting to an
// unreachable address doesn't fail fast - it can hang for a long time before
// giving up. A bounded timeoutMs keeps a misconfigured host from leaving the
// plugin stuck mid-activation instead of surfacing a clear error.
QtObject {
    function check(done) {
        const mpcBin = SettingsData.getPluginSetting("musicRunner", "mpcBin", "mpc");

        Proc.runCommand("musicRunner.depCheck", ["sh", "-c", 'command -v -- "$1"', "sh", mpcBin], (stdout, exitCode) => {
            if (exitCode !== 0) {
                done({
                    "title": "mpc was not found",
                    "details": "'" + mpcBin + "' is not on the shell's PATH. Install mpc (the MPD command-line client), or set an absolute path under this plugin's settings, then re-enable it."
                });
                return;
            }

            const host = SettingsData.getPluginSetting("musicRunner", "mpdHost", "").trim();
            const port = SettingsData.getPluginSetting("musicRunner", "mpdPort", "").trim();
            const args = [mpcBin];
            if (host)
                args.push("--host=" + host);
            if (port)
                args.push("--port=" + port);
            args.push("status");

            Proc.runCommand("musicRunner.connectCheck", args, (out2, code2) => {
                if (code2 === 0) {
                    done(null);
                    return;
                }
                // Proc.runCommand only ever surfaces stdout, not stderr, so
                // mpc's actual error text isn't available here - code 124 is
                // this wrapper's own timeout marker, everything else is mpc's.
                const reason = code2 === 124 ? "mpc did not respond within 5 seconds." : "mpc exited with code " + code2 + ".";
                done({
                    "title": "Could not reach MPD",
                    "details": reason + " Check that MPD is running and that MPD_HOST/MPD_PORT (or this plugin's host/port settings) point at it."
                });
            }, 0, 5000);
        });
    }
}
