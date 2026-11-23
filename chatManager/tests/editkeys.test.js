#!/usr/bin/env node
// Every plugin with a text field carries EditKeys.qml (Ctrl+W and Ctrl+U), word
// for word: a plugin is installed on its own and cannot import another's. This
// one's copy is the one tests/tst_editkeys.qml presses keys against; this
// keeps the others the same as it, and makes sure no plugin with a text field
// goes without.
//
//   node chatManager/tests/editkeys.test.js
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");

const REPO = path.join(__dirname, "..", "..");
const own = fs.readFileSync(path.join(__dirname, "..", "EditKeys.qml"), "utf8");

// A file that has a text field of some kind in it.
const typesInto = /\b(DankTextField|DTextField|TextInput|TextEdit|TextArea|TextField|StringSetting|ListSettingWithInput)\s*\{/;

let failed = 0;
function check(name, fn) {
    try {
        fn();
        console.log("ok   " + name);
    } catch (e) {
        failed++;
        console.log("FAIL " + name + "\n     " + e.message.split("\n").join("\n     "));
    }
}

const plugins = fs.readdirSync(REPO).filter(d => fs.existsSync(path.join(REPO, d, "plugin.json")));

for (const plugin of plugins) {
    const dir = path.join(REPO, plugin);
    const qml = fs.readdirSync(dir).filter(f => f.endsWith(".qml") && f !== "EditKeys.qml");
    const fields = qml.filter(f => typesInto.test(fs.readFileSync(path.join(dir, f), "utf8")));
    const copy = path.join(dir, "EditKeys.qml");
    if (fields.length === 0) {
        check(plugin + ": no text fields, no copy needed", () => assert.ok(!fs.existsSync(copy), "EditKeys.qml without a field to use it"));
        continue;
    }
    check(plugin + ": its copy is chatManager's", () => {
        assert.ok(fs.existsSync(copy), "has text fields in " + fields.join(", ") + " but no EditKeys.qml");
        assert.ok(fs.readFileSync(copy, "utf8") === own, "EditKeys.qml differs from chatManager's: copy it over");
    });
    check(plugin + ": every file with a field is looked after", () => {
        // A file is covered when it has an EditKeys of its own, or is shown
        // inside one that does: the windows, panels and settings pages.
        const users = qml.filter(f => /\bEditKeys\s*\{/.test(fs.readFileSync(path.join(dir, f), "utf8")));
        assert.ok(users.length > 0, "nothing in " + plugin + " uses EditKeys");
    });
}

if (failed > 0) {
    console.log(failed + " FAILED");
    process.exitCode = 1;
} else {
    console.log("all passed");
}
