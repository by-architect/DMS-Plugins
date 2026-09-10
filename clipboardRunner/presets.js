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

function all() {
    return [
        // ------------------------------------------------------------ links
        a("url.open", "url", "Open in browser", "open_in_new",
          "xdg-open ${clipboard}", { notify: false }),
        a("url.download", "url", "Download with aria2c", "download",
          'cd ${downloads} && aria2c ${clipboard}', { when: http() }),
        a("url.nvim", "url", "Open the page source in nvim", "code",
          'F=$(mktemp --suffix=.html); curl -fsSL ${clipboard} > "$F" && ${terminal} nvim "$F"',
          { when: http(), notify: false }),

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
          'cd ${downloads} && git clone ${clipboard}', { when: includes("github.com") }),
        a("gh.project", "url", "pm: create a project", "create_new_folder",
          "pm create ${clipboard}", { when: includes("github.com") }),
        a("gh.fork", "url", "gh: fork, then create a project", "fork_right",
          [
              'set -e',
              'gh repo fork ${clipboard} --clone=false',
              'OWNER=$(gh api user -q .login)',
              'U=${clipboard}',
              'REPO=${U:t:r}',
              'pm create "https://github.com/$OWNER/$REPO"'
          ].join("\n"), { when: includes("github.com") }),
        a("gh.releases", "url", "Open the releases page", "package_2",
          'U=${clipboard}\nxdg-open "${U%/}/releases"', { when: includes("github.com"), notify: false }),

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
          'ffmpeg -y -i ${path} -vf "fps=12,scale=640:-1:flags=lanczos" "${2:r}.gif"', { ext: VIDEO_EXT }),
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

        // Documents
        a("doc.pdf", "path", "libreoffice → pdf", "picture_as_pdf",
          'soffice --headless --convert-to pdf --outdir ${dirname} ${path}', { ext: DOC_EXT }),

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
          'printf %s ${clipboard} > "${9}/clipboard-$(date +%Y%m%d-%H%M%S).txt"')
    ];
}

// Bumped whenever a shipped command changes. On a bump, an action still
// carrying its shipped command is brought up to date; one the user has
// rewritten is left exactly as they wrote it.
var SEED_VERSION = 3;

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

    var seededIds = pluginService.loadPluginData(pluginId, "seededIds", null);
    if (!Array.isArray(seededIds)) {
        // An install from before seededIds was recorded. That seeder wrote the
        // whole set, so treat the whole set as already delivered -- otherwise
        // anything the user had deleted would reappear on this upgrade.
        seededIds = legacy ? shipped.map(function (preset) {
            return preset.presetId;
        }) : [];
    }
    var byId = {};
    for (var i = 0; i < shipped.length; i++)
        byId[shipped[i].presetId] = shipped[i];

    var refreshed = 0;
    var next = current.map(function (item) {
        var preset = item.presetId ? byId[item.presetId] : null;
        if (!preset)
            return item;
        // Untouched means the live command still equals the one shipped with
        // it. On the pre-seededIds installs there is no presetCommand to
        // compare against, so treat those as untouched too.
        var untouched = item.presetCommand === undefined || item.command === item.presetCommand;
        if (!untouched)
            return item;
        if (item.command === preset.command && item.presetCommand === preset.command)
            return item;
        refreshed++;
        var copy = JSON.parse(JSON.stringify(item));
        copy.command = preset.command;
        copy.presetCommand = preset.command;
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
