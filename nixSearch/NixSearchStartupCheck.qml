import QtQuick
import qs.Common

// Gates activation on the nix CLI being reachable from the shell's environment,
// which is not a given even on NixOS if the session PATH is unusual. The
// configured binary is checked rather than a hardcoded "nix", so pointing the
// plugin at an absolute path is enough to unblock it.
QtObject {
    function check(done) {
        const nixBin = SettingsData.getPluginSetting("nixSearch", "nixBin", "nix");

        Proc.runCommand("nixSearch.depCheck", ["sh", "-c", "command -v -- \"$1\"", "sh", nixBin], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": "nix was not found",
                "details": "'" + nixBin + "' is not on the shell's PATH. Install Nix, or set an absolute path (for example /run/current-system/sw/bin/nix) under this plugin's settings, then re-enable it."
            });
        });
    }
}
