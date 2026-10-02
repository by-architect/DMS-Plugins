import QtQuick
import qs.Common

// ssh is the one hard requirement: every check is an ssh. sshpass is not
// checked -- it is only for password hosts, and without it those just say
// so in their row.
QtObject {
    function check(done) {
        Proc.runCommand("hostStatus.depCheck", ["sh", "-c", "command -v ssh >/dev/null 2>&1"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": "ssh was not found",
                "details": "Host Status checks every host over ssh, and 'ssh' is not on the shell's PATH. Install OpenSSH's client, then re-enable this plugin."
            });
        });
    }
}
