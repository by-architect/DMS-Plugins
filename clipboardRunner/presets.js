.pragma library

// The actions the plugin ships with. They are seeded into your action list the
// first time the plugin runs and are ordinary entries from that moment on --
// edit them, retune the filters, delete the ones you have no use for. The
// seeding happens exactly once; deleting one does not bring it back.
//
// Every preset carries a stable presetId so "Restore built-in actions" can put
// back the ones that are missing without duplicating the ones that are not.
//
// Commands run through zsh, detached, with no terminal. Anything slow enough to
// wonder about carries notify: true and says so when it finishes. The two
// exceptions that do open a window are the nvim ones, because an editor cannot
// run without one.

// presetCommand is the command as shipped. Keeping it next to the live one is
// what lets an upgrade tell "still the default" from "the user rewrote this",
// and leave the second kind alone.
function a(presetId, group, name, icon, command, opts) {
    opts = opts || {};
    return {
        presetId: presetId,
        presetCommand: command,
        presetConditions: opts.when || [],
        enabled: true,
        name: name,
        icon: "material:" + icon,
        group: group,
        extensions: opts.ext || "",
        target: opts.target || "any",
        conditions: opts.when || [],
        command: command,
        notify: opts.notify !== false
    };
}

// The shell launches its children with DMS_EXECUTABLE set but with dms itself
// nowhere on PATH, so anything calling back into dms has to go through the
// variable and fall back to the name only for a hand-run shell.
var DMS = '"${DMS_EXECUTABLE:-dms}"';

function includes(value) {
    return [{ op: "includes", value: value, caseSensitive: false }];
}

function startsWith(value) {
    return [{ op: "startsWith", value: value, caseSensitive: false }];
}

// Fetching or downloading only makes sense over http; a magnet has its own
// action and there is nothing to curl at the end of a mailto.
function http() {
    return [{ op: "regex", value: "^https?://", caseSensitive: false }];
}

// A link is a YouTube link under either of its two hostnames.
function youtube() {
    return [{ op: "regex", value: "(youtube\\.com|youtu\\.be)", caseSensitive: false }];
}

// A "convert to X" action has no business appearing for a file that is already
// an X: ffmpeg would be handed the same path as input and output and truncate
// the file. Each conversion therefore drops its own target from the list it
// offers itself for.
function without(list, drop) {
    var gone = drop.split(",").map(function (x) {
        return x.trim().toLowerCase();
    });
    return list.split(",").map(function (x) {
        return x.trim();
    }).filter(function (x) {
        return gone.indexOf(x.toLowerCase()) === -1;
    }).join(", ");
}

var AUDIO_EXT = "mp3, flac, wav, m4a, aac, ogg, opus, wma, aiff, alac";
var VIDEO_EXT = "mp4, mkv, avi, mov, webm, flv, wmv, m4v, mpg, mpeg, ts";
var IMAGE_EXT = "png, jpg, jpeg, webp, gif, bmp, tiff, tif, avif, heic, heif";
var DOC_EXT = "doc, docx, odt, ods, odp, xls, xlsx, ppt, pptx, rtf, txt, md, csv";
var APK_EXT = "apk, xapk, apks, aab";
// The tail of a .tar.gz is what the ext parser sees, so the compound names are
// covered by their last component.
var ARCHIVE_EXT = "zip, 7z, rar, tar, gz, tgz, bz2, tbz, tbz2, xz, txz, zst, tzst, lz4, lzma, cab, arj, lzh, iso, cpio, wim, deb, rpm";

// The one place a terminal is opened on purpose: listing an archive is
// something you read, so it goes to a pager rather than a notification. 7z is
// asked first and the output parked in a file, which keeps the terminal
// invocation free of any nested quoting.
var ARCHIVE_LIST = [
    'F=$(mktemp)',
    '{ print -r -- ${path}; print; 7z l ${path}; } > "$F" 2>&1',
    '${terminal} less -R "$F"'
].join("\n");

// Reading an APK's framework off the names inside it. aapt and apktool are not
// needed for this -- the giveaway is which native library got bundled, and that
// is visible in the zip listing alone. An xapk/apks is a zip of apks, so the
// listing is searched the same way and finds the inner names too.
var APK_FRAMEWORK = [
    'L=$(unzip -Z1 "${2}" 2>/dev/null)',
    'case "$L" in',
    '  *libflutter.so*)         F="Flutter (Dart)" ;;',
    '  *libreactnativejni.so*|*libhermes.so*) F="React Native (JavaScript)" ;;',
    '  *libunity.so*)           F="Unity (C#)" ;;',
    '  *libmonodroid.so*|*libmonosgen*) F="Xamarin / .NET MAUI (C#)" ;;',
    '  *libcordova*|*/assets/www/*) F="Cordova / Ionic (web)" ;;',
    '  *libqt5*|*libQt5*|*libQt6*) F="Qt (C++)" ;;',
    '  *libgodot*|*libgdnative*) F="Godot" ;;',
    '  *kotlin/kotlin.kotlin_builtins*) F="Kotlin" ;;',
    '  *classes.dex*)           F="Java or Kotlin (no framework marker)" ;;',
    '  *)                       F="unrecognised" ;;',
    'esac',
    'notify-send -a "Clipboard Runner" "${4}" "$F"'
].join("\n");

// Install an AppImage where the launcher will find it: the binary on PATH, an
// icon in the hicolor theme, and a desktop entry pointing at both. AppImages
// carry their own icon and .desktop inside, so those are taken from the file
// itself rather than invented; if extraction fails a minimal entry is written
// so the app is still launchable.
var APPIMAGE_INSTALL = [
    'set -e',
    'BIN="$HOME/.local/bin"; APPS="$HOME/.local/share/applications"; ICONS="$HOME/.local/share/icons/hicolor/256x256/apps"',
    'mkdir -p "$BIN" "$APPS" "$ICONS"',
    'NAME="${4:r}"',
    'DEST="$BIN/${4}"',
    'cp "${2}" "$DEST"',
    'chmod +x "$DEST"',
    'WORK=$(mktemp -d)',
    'cd "$WORK"',
    'if "$DEST" --appimage-extract >/dev/null 2>&1; then',
    '  SRC=$(find squashfs-root -maxdepth 1 -name "*.desktop" 2>/dev/null | head -n1)',
    '  ICON=$(find squashfs-root -maxdepth 1 \\( -name "*.png" -o -name "*.svg" \\) 2>/dev/null | head -n1)',
    '  [ -n "$ICON" ] && cp "$ICON" "$ICONS/$NAME.${ICON##*.}"',
    '  if [ -n "$SRC" ]; then',
    "    sed -e 's|^Exec=.*|Exec=\"'\"$DEST\"'\" %U|' -e \"s|^Icon=.*|Icon=$NAME|\" \"$SRC\" > \"$APPS/$NAME.desktop\"",
    '  fi',
    'fi',
    'if [ ! -f "$APPS/$NAME.desktop" ]; then',
    '  cat > "$APPS/$NAME.desktop" <<DESKTOP',
    '[Desktop Entry]',
    'Type=Application',
    'Name=$NAME',
    'Exec="$DEST" %U',
    'Icon=$NAME',
    'Categories=Utility;',
    'DESKTOP',
    'fi',
    'cd /',
    'rm -rf "$WORK"',
    'update-desktop-database "$APPS" 2>/dev/null || true'
].join("\n");

// sm install then play: sm files the track and updates mpd's database, so the
// newest thing in the library is what was just added. --wait keeps the update
// from racing the search.
var SM_INSTALL_PLAY = [
    'sm music install "${1}"',
    'mpc update --wait >/dev/null',
    'NEW=$(mpc listall --format "%file%" | tail -n 1)',
    '[ -n "$NEW" ] && mpc add "$NEW" && mpc play'
].join("\n");

// A git remote as the web page it belongs to, in $U. The ssh forms,
// git@host:owner/repo.git and ssh://git@host/owner/repo.git, have no page of
// their own, so they are rewritten to https before anything opens or forks
// them; an https link only loses a trailing slash and ".git".
var WEB_URL = [
    'U=${clipboard}',
    'if [[ $U == git@*:* || $U == ssh://git@* ]]; then U=${U#ssh://}; U=${U#*@}; U=${U/:/\\/}; U="https://$U"; fi',
    'U=${U%/}; U=${U%.git}'
].join("\n");

// Any forge, by the word in its hostname, whether the link is https or ssh.
function forge(name) {
    return [{ op: "regex", value: "^(https?://|ssh://|git@)([^/]*[.@])?" + name + "\\.", caseSensitive: false }];
}

// Sites yt-dlp can pull a video from, besides YouTube (which has its own
// actions). Matched on the hostname, so a link that merely mentions one in its
// path does not count.
var VIDEO_SITES = "x\\.com|twitter\\.com|instagram\\.com|tiktok\\.com|vimeo\\.com|reddit\\.com|v\\.redd\\.it|twitch\\.tv|dailymotion\\.com|streamable\\.com|facebook\\.com|fb\\.watch|bsky\\.app|bilibili\\.com";

function onSite(hosts) {
    return [{ op: "regex", value: "^https?://([^/?#]*\\.)?(" + hosts + ")([/:?#]|$)", caseSensitive: false }];
}

// Query parameters that only exist to say where a link was clicked. The same
// list decides when "Remove tracking" is offered and what it removes.
var TRACKING = "utm_\\w+|fbclid|gclid|dclid|gbraid|wbraid|msclkid|mc_cid|mc_eid|igsh|igshid|si|ref_src|ref_url|_hsenc|_hsmi|mkt_tok|yclid|twclid|ttclid|srsltid|_ga|_gl";

// The query is filtered as written rather than parsed and rebuilt, so every
// parameter that stays keeps its exact encoding.
var URL_CLEAN = [
    'C=$(python3 -c \'import re,sys,urllib.parse as p;u=p.urlsplit(sys.argv[1]);j=re.compile(r"^(' + TRACKING + ')$",re.I);q="&".join(x for x in u.query.split("&") if x and not j.match(p.unquote_plus(x.split("=",1)[0])));print(p.urlunsplit(u._replace(query=q)))\' ${clipboard})',
    'printf %s "$C" | "${DMS_EXECUTABLE:-dms}" cl copy',
    'notify-send -a "Clipboard Runner" "Clean link copied" "$C"'
].join("\n");

// One palette built from the clip itself, instead of a generic 256 colours, is
// what keeps a GIF's gradients and UI greys from banding; stats_mode=diff
// spends it on what moves, which suits screen recordings. Never wider than the
// source, so a small clip is not blown up.
var VIDEO_GIF = 'ffmpeg -y -i ${path} -vf "fps=12,scale=min(640\\,iw):-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -loop 0 "${2:r}.gif"';

// Small enough for a chat app's upload limit: the long edge at most 1280,
// never enlarged, H.264 and AAC so anything plays it, and the index up front
// so it starts before it has finished downloading.
var VIDEO_SMALL = 'ffmpeg -y -i ${path} -vf "scale=w=min(1280\\,iw):h=min(1280\\,ih):force_original_aspect_ratio=decrease:force_divisible_by=2" -c:v libx264 -preset veryfast -crf 26 -c:a aac -b:a 128k -movflags +faststart "${2:r}-small.mp4"';

var IMAGE_OCR = [
    'T=$(tesseract ${path} - -l eng -c page_separator= 2>/dev/null)',
    'if [ -n "${T//[[:space:]]/}" ]; then',
    '    printf %s "$T" | "${DMS_EXECUTABLE:-dms}" cl copy',
    '    notify-send -a "Clipboard Runner" "Text copied" "${T[1,300]}"',
    'else',
    '    notify-send -a "Clipboard Runner" ${basename} "No text found"',
    'fi'
].join("\n");

// Brief mode, through stdin so a text starting with "-" is not read as an
// option; translate-shell needs the network, hence the timeout.
var TEXT_TRANSLATE = [
    'R=$(printf %s ${clipboard} | timeout 30 trans -b :en 2>/dev/null)',
    'if [ -n "$R" ]; then',
    '    printf %s "$R" | "${DMS_EXECUTABLE:-dms}" cl copy',
    '    notify-send -a "Clipboard Runner" "Translation copied" "${R[1,300]}"',
    'else',
    '    notify-send -a "Clipboard Runner" "Translation failed" "translate-shell gave nothing back -- offline?"',
    'fi'
].join("\n");

var TEXT_JSON = [
    'R=$(printf %s ${clipboard} | jq . 2>&1)',
    'if [ $? -eq 0 ]; then',
    '    printf %s "$R" | "${DMS_EXECUTABLE:-dms}" cl copy',
    '    notify-send -a "Clipboard Runner" "Formatted JSON copied" "${#${(f)R}} lines"',
    'else',
    '    notify-send -a "Clipboard Runner" "Not valid JSON" "$R"',
    'fi'
].join("\n");

// The filter only lets digits and operators through, and the command checks
// again before Python evaluates anything, with no builtins and a timeout -- so
// "9^9^9" gives up rather than eating the machine.
var TEXT_CALC = [
    'R=$(timeout 3 python3 -c \'import re,sys;e=sys.argv[1].replace("^","**");re.fullmatch(r"[\\d\\s.+\\-*/%()]+",e) or sys.exit(1);v=eval(e,{"__builtins__":{}});print(int(v) if isinstance(v,float) and v.is_integer() else round(v,10))\' ${clipboard} 2>/dev/null)',
    'if [ -n "$R" ]; then',
    '    printf %s "$R" | "${DMS_EXECUTABLE:-dms}" cl copy',
    '    notify-send -a "Clipboard Runner" "= $R (copied)" ${clipboard}',
    'else',
    '    notify-send -a "Clipboard Runner" "Could not calculate" ${clipboard}',
    'fi'
].join("\n");

// Ghostscript's ebook preset resamples images to 150 dpi, which is what makes a
// scanned or photo-heavy PDF small. One that is mostly text can come out
// larger instead, and then the original is kept as the only copy.
var PDF_SMALL = [
    'O="${2:r}-small.pdf"',
    'if ! gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.5 -dPDFSETTINGS=/ebook -dNOPAUSE -dBATCH -dQUIET -sOutputFile="$O" ${path}; then',
    '    notify-send -a "Clipboard Runner" -u critical ${basename} "Ghostscript could not read it"',
    'elif [ "$(stat -c %s "$O")" -lt "$(stat -c %s ${path})" ]; then',
    '    notify-send -a "Clipboard Runner" "PDF shrunk" "${O:t}: $(du -h ${path} | cut -f1) → $(du -h "$O" | cut -f1)"',
    'else',
    '    rm -f "$O"',
    '    notify-send -a "Clipboard Runner" ${basename} "Already as small as it gets -- nothing written"',
    'fi'
].join("\n");

var FILE_SHA256 = [
    'H=$(sha256sum ${path} | cut -d" " -f1)',
    'printf %s "$H" | "${DMS_EXECUTABLE:-dms}" cl copy',
    'notify-send -a "Clipboard Runner" "SHA-256 copied" "${basename}: $H"'
].join("\n");

function all() {
    return [
        // ------------------------------------------------------------ links
        a("url.open", "url", "Open in browser", "open_in_new",
          "xdg-open ${clipboard}", { when: [{ op: "notRegex", value: "^(git@|ssh://)", caseSensitive: false }], notify: false }),
        a("git.open", "url", "Open the repository in the browser", "open_in_new",
          WEB_URL + '\nxdg-open "$U"', { when: [{ op: "regex", value: "^(git@[^:]+:|ssh://git@)", caseSensitive: false }], notify: false }),
        a("url.download", "url", "Download with aria2c", "download",
          'cd ${downloads} && aria2c ${clipboard}', { when: http() }),
        a("url.nvim", "url", "Open the page source in nvim", "code",
          'F=$(mktemp --suffix=.html); curl -fsSL ${clipboard} > "$F" && ${terminal} nvim "$F"',
          { when: http(), notify: false }),
        a("url.clean", "url", "Remove tracking from the link (copies it)", "link_off",
          URL_CLEAN, { when: [{ op: "regex", value: "[?&](" + TRACKING + ")=", caseSensitive: false }], notify: false }),
        a("url.mpv", "url", "mpv: play it", "live_tv",
          "mpv ${clipboard}", { when: onSite("youtube\\.com|youtu\\.be|" + VIDEO_SITES), notify: false }),

        // Other video sites
        a("site.video", "url", "yt-dlp: download video", "smart_display",
          'cd ${downloads} && yt-dlp ${clipboard}', { when: onSite(VIDEO_SITES) }),

        // YouTube
        a("yt.video", "url", "yt-dlp: download video", "smart_display",
          'cd ${downloads} && yt-dlp ${clipboard}', { when: youtube() }),
        a("yt.audio", "url", "yt-dlp: download audio", "music_note",
          'cd ${downloads} && yt-dlp -x --audio-format mp3 ${clipboard}', { when: youtube() }),
        a("yt.sm", "url", "sm: install into the music library", "library_music",
          "sm music install ${clipboard}", { when: youtube() }),
        a("yt.smplay", "url", "sm: install and play", "play_circle",
          SM_INSTALL_PLAY, { when: youtube() }),

        // Deezer
        a("dz.sm", "url", "sm: install into the music library", "library_music",
          "sm music install ${clipboard}", { when: includes("deezer.com") }),
        a("dz.smplay", "url", "sm: install and play", "play_circle",
          SM_INSTALL_PLAY, { when: includes("deezer.com") }),

        // Torrents
        a("magnet.aria2", "url", "aria2c: download this magnet", "magnet_bookmark",
          'cd ${downloads} && aria2c --seed-time=0 ${clipboard}', { when: startsWith("magnet:") }),

        // GitHub
        a("gh.clone", "url", "Clone into downloads", "download_for_offline",
          'cd ${downloads} && git clone ${clipboard}', { when: forge("github") }),
        a("gh.project", "url", "pm: create a project", "create_new_folder",
          "pm create ${clipboard}", { when: forge("github") }),
        a("gh.fork", "url", "gh: fork, then create a project", "fork_right",
          [
              'set -e',
              WEB_URL,
              'gh repo fork "$U" --clone=false',
              'OWNER=$(gh api user -q .login)',
              'pm create "https://github.com/$OWNER/${U:t}"'
          ].join("\n"), { when: forge("github") }),
        a("gh.releases", "url", "Open the releases page", "package_2",
          WEB_URL + '\nxdg-open "$U/releases"', { when: forge("github"), notify: false }),

        // GitLab, gitlab.com or any instance with gitlab in its hostname.
        // Releases live under /-/ there, and a fork lands on the same host.
        a("gl.clone", "url", "Clone into downloads", "download_for_offline",
          'cd ${downloads} && git clone ${clipboard}', { when: forge("gitlab") }),
        a("gl.project", "url", "pm: create a project", "create_new_folder",
          "pm create ${clipboard}", { when: forge("gitlab") }),
        a("gl.fork", "url", "glab: fork, then create a project", "fork_right",
          [
              'set -e',
              WEB_URL,
              'HOST=${${U#https://}%%/*}',
              'GITLAB_HOST=$HOST glab repo fork "$U" --clone=false',
              'OWNER=$(GITLAB_HOST=$HOST glab api user | jq -r .username)',
              'pm create "https://$HOST/$OWNER/${U:t}"'
          ].join("\n"), { when: forge("gitlab") }),
        a("gl.releases", "url", "Open the releases page", "package_2",
          WEB_URL + '\nxdg-open "$U/-/releases"', { when: forge("gitlab"), notify: false }),

        // ----------------------------------------------------------- colors
        a("color.tohex", "color", "rgb → hex (copies the result)", "tag",
          'H=$(python3 -c \'import re,sys;v=[int(float(x)) for x in re.findall(r"[\\d.]+", sys.argv[1])[:3]];print("#%02x%02x%02x"%tuple(v))\' ${clipboard})\nprintf %s "$H" | "${DMS_EXECUTABLE:-dms}" cl copy\nnotify-send -a "Clipboard Runner" "${clipboard}" "$H"',
          { when: startsWith("rgb"), notify: false }),
        a("color.torgb", "color", "hex → rgb (copies the result)", "palette",
          'H=$(python3 -c \'import sys;h=sys.argv[1].lstrip("#");h="".join(c*2 for c in h) if len(h) in (3,4) else h;print("rgb(%d, %d, %d)"%tuple(int(h[i:i+2],16) for i in (0,2,4)))\' ${color})\nprintf %s "$H" | "${DMS_EXECUTABLE:-dms}" cl copy\nnotify-send -a "Clipboard Runner" "${clipboard}" "$H"',
          { when: startsWith("#"), notify: false }),
        a("color.tohsl", "color", "hex → hsl (copies the result)", "gradient",
          'H=$(python3 -c \'import sys,colorsys;h=sys.argv[1].lstrip("#");h="".join(c*2 for c in h) if len(h) in (3,4) else h;r,g,b=(int(h[i:i+2],16)/255 for i in (0,2,4));hh,l,s=colorsys.rgb_to_hls(r,g,b);print("hsl(%d, %d%%, %d%%)"%(round(hh*360),round(s*100),round(l*100)))\' ${color})\nprintf %s "$H" | "${DMS_EXECUTABLE:-dms}" cl copy\nnotify-send -a "Clipboard Runner" "${clipboard}" "$H"',
          { when: startsWith("#"), notify: false }),
        a("color.swatch", "color", "Save a swatch to downloads", "image",
          'C=${color}\nmagick -size 512x512 "xc:$C" ${downloads}/swatch-"${C#\\#}".png'),

        // ------------------------------------------------------------ files
        a("file.open", "path", "Open", "open_in_new",
          "xdg-open ${path}", { notify: false }),
        a("file.reveal", "path", "Open the containing folder", "folder_open",
          "xdg-open ${dirname}", { notify: false }),
        a("file.nvim", "path", "Open in nvim", "code",
          "${terminal} nvim ${path}", { target: "file", notify: false }),
        a("file.scan", "path", "Virus scan", "shield",
          'R=$(clamdscan --fdpass --no-summary ${path} 2>&1)\nnotify-send -a "Clipboard Runner" "${basename}" "$R"',
          { notify: false }),
        a("file.copyPath", "path", "Copy the path as text", "content_copy",
          'printf %s ${path} | "${DMS_EXECUTABLE:-dms}" cl copy', { notify: false }),
        a("file.sha256", "path", "SHA-256 checksum (copies it)", "fingerprint",
          FILE_SHA256, { target: "file", notify: false }),

        // Audio
        a("audio.mp3", "path", "ffmpeg → mp3", "music_note",
          'ffmpeg -y -i ${path} -codec:a libmp3lame -q:a 2 "${2:r}.mp3"', { ext: without(AUDIO_EXT, "mp3") }),
        a("audio.flac", "path", "ffmpeg → flac", "music_note",
          'ffmpeg -y -i ${path} "${2:r}.flac"', { ext: without(AUDIO_EXT, "flac") }),
        a("audio.opus", "path", "ffmpeg → opus", "music_note",
          'ffmpeg -y -i ${path} -codec:a libopus -b:a 128k "${2:r}.opus"', { ext: without(AUDIO_EXT, "opus") }),
        a("audio.wav", "path", "ffmpeg → wav", "music_note",
          'ffmpeg -y -i ${path} "${2:r}.wav"', { ext: without(AUDIO_EXT, "wav") }),

        // Video
        a("video.mp4", "path", "ffmpeg → mp4", "movie",
          'ffmpeg -y -i ${path} -c:v libx264 -crf 20 -c:a aac "${2:r}.mp4"', { ext: without(VIDEO_EXT, "mp4") }),
        a("video.mkv", "path", "ffmpeg → mkv", "movie",
          'ffmpeg -y -i ${path} -c copy "${2:r}.mkv"', { ext: without(VIDEO_EXT, "mkv") }),
        a("video.webm", "path", "ffmpeg → webm", "movie",
          'ffmpeg -y -i ${path} -c:v libvpx-vp9 -crf 32 -b:v 0 -c:a libopus "${2:r}.webm"', { ext: without(VIDEO_EXT, "webm") }),
        a("video.gif", "path", "ffmpeg → gif", "gif",
          VIDEO_GIF, { ext: VIDEO_EXT }),
        a("video.small", "path", "ffmpeg: shrink for sharing (mp4)", "compress",
          VIDEO_SMALL, { ext: VIDEO_EXT }),
        a("video.frame", "path", "ffmpeg: save a still frame", "photo",
          'ffmpeg -y -i ${path} -vf thumbnail -frames:v 1 -update 1 "${2:r}-frame.png"', { ext: VIDEO_EXT }),
        a("video.mute", "path", "ffmpeg: remove the sound", "volume_off",
          'ffmpeg -y -i ${path} -c copy -an "${2:r}-silent.${3}"', { ext: VIDEO_EXT }),
        a("video.audio", "path", "ffmpeg: pull the audio out", "music_note",
          'ffmpeg -y -i ${path} -vn -codec:a libmp3lame -q:a 2 "${2:r}.mp3"', { ext: VIDEO_EXT }),

        // Images
        a("image.png", "path", "magick → png", "image",
          'magick ${path} "${2:r}.png"', { ext: without(IMAGE_EXT, "png") }),
        a("image.jpg", "path", "magick → jpg", "image",
          'magick ${path} -quality 92 "${2:r}.jpg"', { ext: without(IMAGE_EXT, "jpg, jpeg") }),
        a("image.webp", "path", "magick → webp", "image",
          'magick ${path} -quality 88 "${2:r}.webp"', { ext: without(IMAGE_EXT, "webp") }),
        a("image.avif", "path", "magick → avif", "image",
          'magick ${path} -quality 55 "${2:r}.avif"', { ext: without(IMAGE_EXT, "avif") }),
        a("image.pdf", "path", "magick → pdf", "picture_as_pdf",
          'magick ${path} "${2:r}.pdf"', { ext: IMAGE_EXT }),
        a("image.ocr", "path", "tesseract: copy the text in it", "document_scanner",
          IMAGE_OCR, { ext: IMAGE_EXT, notify: false }),
        a("image.small", "path", "magick: shrink for sharing", "compress",
          'magick ${path} -auto-orient -resize "1920x1920>" -quality 85 "${2:r}-small.${3}"', { ext: without(IMAGE_EXT, "gif") }),
        // Turned upright first: the orientation is part of what -strip removes.
        a("image.strip", "path", "magick: remove location and camera data", "location_off",
          'magick ${path} -auto-orient -strip "${2:r}-clean.${3}"', { ext: "jpg, jpeg, png, webp, tiff, tif, avif, heic, heif" }),

        // Documents
        a("doc.pdf", "path", "libreoffice → pdf", "picture_as_pdf",
          'soffice --headless --convert-to pdf --outdir ${dirname} ${path}', { ext: DOC_EXT }),
        a("pdf.small", "path", "ghostscript: shrink the PDF", "compress",
          PDF_SMALL, { ext: "pdf", notify: false }),

        // Folders
        a("dir.zip", "path", "Compress to zip", "folder_zip",
          'cd ${dirname} && 7z a -tzip ${basename}.zip ${basename}', { target: "dir" }),
        a("dir.7z", "path", "Compress to 7z", "folder_zip",
          'cd ${dirname} && 7z a -t7z ${basename}.7z ${basename}', { target: "dir" }),
        a("dir.targz", "path", "Compress to tar.gz", "folder_zip",
          'cd ${dirname} && tar czf ${basename}.tar.gz ${basename}', { target: "dir" }),
        a("dir.terminal", "path", "Open a terminal here", "terminal",
          'cd ${path} && ${terminal} zsh', { target: "dir", notify: false }),

        // Archives
        a("archive.extract", "path", "Extract it here", "unarchive",
          'cd ${dirname} && 7z x -o"${4:r}" -y ${path}', { ext: ARCHIVE_EXT, target: "file" }),
        a("archive.extractDownloads", "path", "Extract into downloads", "drive_folder_upload",
          'cd ${downloads} && 7z x -o"${4:r}" -y ${path}', { ext: ARCHIVE_EXT, target: "file" }),
        a("archive.list", "path", "Show what is inside", "list",
          ARCHIVE_LIST, { ext: ARCHIVE_EXT, target: "file", notify: false }),

        // Android
        a("apk.framework", "path", "What is this written in?", "code_blocks",
          APK_FRAMEWORK, { ext: APK_EXT, notify: false }),
        a("apk.install", "path", "adb: install on the connected device", "android",
          "adb install -r ${path}", { ext: APK_EXT }),

        // AppImage
        a("appimage.install", "path", "Install it", "install_desktop",
          APPIMAGE_INSTALL, { ext: "appimage" }),
        a("appimage.run", "path", "Run it once", "play_arrow",
          "appimage-run ${path}", { ext: "appimage", notify: false }),

        // ------------------------------------------------------------- text
        a("text.nvim", "text", "Open in nvim", "code",
          'F=$(mktemp --suffix=.txt); printf %s ${clipboard} > "$F"; ${terminal} nvim "$F"',
          { notify: false }),
        a("text.search", "text", "Search the web for it", "search",
          'xdg-open "https://duckduckgo.com/?q=$(python3 -c \'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))\' ${clipboard})"',
          { notify: false }),
        a("text.save", "text", "Save it to downloads", "save",
          'printf %s ${clipboard} > "${9}/clipboard-$(date +%Y%m%d-%H%M%S).txt"'),
        a("text.translate", "text", "Translate to English (copies it)", "translate",
          TEXT_TRANSLATE, { notify: false }),
        a("text.json", "text", "Format JSON (copies it)", "data_object",
          TEXT_JSON, { when: [{ op: "regex", value: "^\\s*[\\[{]", caseSensitive: false }], notify: false }),
        // Offered only for arithmetic: digits, an operator between two of them,
        // and nothing else.
        a("text.calc", "text", "Calculate (copies the result)", "calculate",
          TEXT_CALC, { when: [{ op: "regex", value: "^[\\d\\s.+\\-*/%()^]*\\d\\s*[+\\-*/%^]\\s*[\\d(.][\\d\\s.+\\-*/%()^]*$", caseSensitive: false }], notify: false })
    ];
}

// Bumped whenever a shipped command changes. On a bump, an action still
// carrying its shipped command is brought up to date; one the user has
// rewritten is left exactly as they wrote it.
var SEED_VERSION = 6;

// The filters shipped before presetConditions was recorded, for the presets
// whose filters have changed since. Anything not listed here keeps whatever
// filters it has.
var EARLIER_CONDITIONS = {
    "url.open": [],
    "gh.clone": includes("github.com"),
    "gh.project": includes("github.com"),
    "gh.fork": includes("github.com"),
    "gh.releases": includes("github.com")
};

function same(a, b) {
    return JSON.stringify(a) === JSON.stringify(b);
}

// Seeding runs once. seededIds records every preset that has ever been written
// into the list, so a later version can tell a genuinely new action from one
// the user deleted on purpose -- deleted ones stay deleted.
function seedIfNeeded(pluginService, pluginId) {
    if (!pluginService)
        return "";

    var version = pluginService.loadPluginData(pluginId, "seedVersion", 0);
    if (typeof version !== "number")
        version = 0;
    if (version >= SEED_VERSION)
        return "";

    var current = pluginService.loadPluginData(pluginId, "actions", []);
    if (!Array.isArray(current))
        current = [];

    var legacy = pluginService.loadPluginData(pluginId, "seeded", false) === true;
    var firstRun = version === 0 && !legacy;

    var shipped = all();

    // What counts as "already delivered". Two records cannot be trusted and are
    // rebuilt from the list as it actually stands:
    //
    //   - an install from before seededIds existed, which has no record at all;
    //   - one written by seedVersion 3, which recorded every shipped id
    //     including ones it then failed to add, and so would withhold them
    //     forever.
    //
    // Rebuilding costs one thing: a preset deleted before the repair comes back
    // a single time. That is the better failure -- the alternative is new
    // actions silently never arriving -- and once the record is sound it stops
    // happening.
    var recorded = pluginService.loadPluginData(pluginId, "seededIds", null);
    var trustworthy = Array.isArray(recorded) && !legacy && version >= 4;
    var seededIds = trustworthy ? recorded : current.map(function (item) {
        return item.presetId;
    }).filter(function (id) {
        return !!id;
    });

    var byId = {};
    for (var i = 0; i < shipped.length; i++)
        byId[shipped[i].presetId] = shipped[i];

    var refreshed = 0;
    var next = current.map(function (item) {
        var preset = item.presetId ? byId[item.presetId] : null;
        if (!preset)
            return item;
        var copy = JSON.parse(JSON.stringify(item));
        var changed = false;

        // Untouched means the live command still equals the one shipped with
        // it. On the pre-seededIds installs there is no presetCommand to
        // compare against, so treat those as untouched too.
        var untouched = item.presetCommand === undefined || item.command === item.presetCommand;
        if (untouched && !(item.command === preset.command && item.presetCommand === preset.command)) {
            copy.command = preset.command;
            copy.presetCommand = preset.command;
            changed = true;
        }

        // Filters the same way, judged on their own so that retuning one
        // does not freeze the other. Entries from before presetConditions
        // was recorded are compared with what that version shipped.
        var shippedBefore = item.presetConditions !== undefined ? item.presetConditions : EARLIER_CONDITIONS[item.presetId];
        var filtersUntouched = shippedBefore !== undefined && same(item.conditions || [], shippedBefore);
        if (filtersUntouched && !(same(item.conditions || [], preset.conditions) && same(shippedBefore, preset.conditions))) {
            copy.conditions = preset.conditions;
            copy.presetConditions = preset.conditions;
            changed = true;
        }

        if (!changed)
            return item;
        refreshed++;
        return copy;
    });

    var known = {};
    for (var k = 0; k < seededIds.length; k++)
        known[seededIds[k]] = true;

    var added = shipped.filter(function (preset) {
        return firstRun || !known[preset.presetId];
    });

    if (!firstRun && added.length > 0)
        next = next.concat(added);
    else if (firstRun)
        next = current.concat(added);

    var allIds = seededIds.slice();
    for (var m = 0; m < shipped.length; m++) {
        if (!known[shipped[m].presetId])
            allIds.push(shipped[m].presetId);
    }

    pluginService.savePluginData(pluginId, "actions", next);
    pluginService.savePluginData(pluginId, "seededIds", allIds);
    pluginService.savePluginData(pluginId, "seedVersion", SEED_VERSION);

    if (firstRun)
        return "seeded " + added.length + " built-in actions";
    var parts = [];
    if (added.length > 0)
        parts.push("added " + added.length);
    if (refreshed > 0)
        parts.push("updated " + refreshed);
    return parts.length > 0 ? "built-in actions: " + parts.join(", ") : "";
}

// Put back the presets that are no longer in the list, leaving edited copies of
// the others alone. Matching is by presetId, so renaming one does not make it
// come back twice.
function restoreMissing(current) {
    var have = {};
    for (var i = 0; i < (current || []).length; i++) {
        if (current[i].presetId)
            have[current[i].presetId] = true;
    }

    var missing = all().filter(function (preset) {
        return !have[preset.presetId];
    });

    return { actions: (current || []).concat(missing), added: missing.length };
}
