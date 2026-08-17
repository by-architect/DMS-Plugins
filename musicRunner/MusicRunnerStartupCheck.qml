import QtQuick
import qs.Common

// Only verifies the mpc binary is present - not that MPD is actually
// reachable. MPD being down is a normal, recoverable, often-temporary state
// (a remote server rebooting, a laptop closed) and blocking activation on it
// would make the whole plugin unusable until it happens to come back at the
// exact moment you enable it. Instead, connectivity is checked continuously
// at runtime and surfaced as a normal "MPD not connected" result row - see
// _mpdError in MusicRunnerLauncher.qml - so the launcher stays usable and
// clearly explains itself either way.
QtObject {
    function check(done) {
        const mpcBin = SettingsData.getPluginSetting("musicRunner", "mpcBin", "mpc");

        Proc.runCommand("musicRunner.depCheck", ["sh", "-c", 'command -v -- "$1"', "sh", mpcBin], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": "mpc was not found",
                "details": "'" + mpcBin + "' is not on the shell's PATH. Install mpc (the MPD command-line client), or set an absolute path under this plugin's settings, then re-enable it."
            });
        });
    }
}
