import QtQuick
import qs.Common

// Gates activation on the core capture tools being reachable from the shell's
// environment. tesseract (OCR) and ffmpeg (GIF conversion) are optional extras
// checked at the point of use instead, since screenshots and mp4 recording work
// fine without them.
QtObject {
    function check(done) {
        Proc.runCommand("screenCatcher.depCheck", ["sh", "-c", "command -v grim >/dev/null 2>&1 && command -v slurp >/dev/null 2>&1 && command -v wf-recorder >/dev/null 2>&1"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": "Missing screenshot/recording tools",
                "details": "Screen Catcher needs grim, slurp and wf-recorder on the shell's PATH. Install them, then re-enable this plugin. (Optional: tesseract for 'Screenshot to Text', ffmpeg for GIF recording, wl-clipboard for clipboard copy, pipewire-pulse/pactl for audio device detection.)"
            });
        });
    }
}
