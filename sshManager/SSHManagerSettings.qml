import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Custom rather than ListSettingWithInput -- that widget echoes every field
// of every row back as plain text, which is fine for commandRunner's
// commands but wrong for a password. Passwords never round-trip through
// this screen once saved: this form only ever writes one, through the
// daemon (see SSHManagerDaemon.qml's "secrets" section for where it lands).
PluginSettings {
    id: root

    pluginId: "sshManager"

    readonly property var daemon: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        return instances["sshManager"] ?? null;
    }

    property var hosts: []
    property string newAuthMethod: "key"

    property int editingPasswordIndex: -1

    function _loadHosts() {
        const loaded = root.loadValue("hosts", []);
        hosts = Array.isArray(loaded) ? loaded : [];
    }

    Component.onCompleted: Qt.callLater(_loadHosts)
    onPluginServiceChanged: _loadHosts()

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadHosts();
        }
    }

    function _saveHosts(newHosts) {
        hosts = newHosts;
        root.saveValue("hosts", newHosts);
    }

    function addHost(nameText, hostText, portText, usernameText, identityFileText, passwordText) {
        const host = (hostText || "").trim();
        if (host.length === 0)
            return;

        const id = "h" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
        const authMethod = root.newAuthMethod === "password" ? "password" : "key";
        const entry = {
            id: id,
            name: (nameText || "").trim() || host,
            host: host,
            port: (portText || "").trim() || "22",
            username: (usernameText || "").trim(),
            authMethod: authMethod,
            identityFile: (identityFileText || "").trim(),
            hasPassword: false
        };
        root._saveHosts(root.hosts.concat([entry]));

        if (authMethod === "password" && (passwordText || "").length > 0) {
            if (root.daemon) {
                root.daemon.setPassword(id, passwordText);
                root._saveHosts(root.hosts.map(h => h.id === id ? Object.assign({}, h, {
                    hasPassword: true
                }) : h));
            } else if (typeof ToastService !== "undefined") {
                ToastService.showWarning("Password not saved", "Enable this plugin first, then set the password from the host row below.");
            }
        }
    }

    function removeHost(hostId) {
        root._saveHosts(root.hosts.filter(h => h.id !== hostId));
        if (root.daemon)
            root.daemon.clearPassword(hostId);
    }

    function savePasswordFor(hostId, password) {
        if (!root.daemon) {
            if (typeof ToastService !== "undefined")
                ToastService.showWarning("Password not saved", "Enable this plugin first.");
            return;
        }
        root.daemon.setPassword(hostId, password);
        root._saveHosts(root.hosts.map(h => h.id === hostId ? Object.assign({}, h, {
            hasPassword: password.length > 0
        }) : h));
        root.editingPasswordIndex = -1;
    }

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix that activates the launcher. The trailing space keeps unrelated words from matching."
        placeholder: "ssh "
        defaultValue: "ssh "
    }

    StringSetting {
        settingKey: "terminalBin"
        label: "Terminal"
        description: "Terminal emulator to open when connecting to a host."
        placeholder: "ghostty"
        defaultValue: "ghostty"
    }

    StringSetting {
        settingKey: "terminalArgsOverride"
        label: "Terminal exec flags (optional)"
        description: "Space-separated flags placed between the terminal binary and the ssh command, e.g. '-e' or 'start --'. Leave blank to auto-detect for ghostty, kitty, alacritty, foot, wezterm, gnome-terminal, xterm, konsole, st, terminator and xfce4-terminal."
        placeholder: "-e"
        defaultValue: ""
    }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.outline
            opacity: 0.3
        }

        StyledText {
            text: "Hosts"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            text: "Shared with this plugin's own 'ssh <name>' launcher and with any other installed plugin that looks up sshManager's host list (e.g. a runner). Key-based auth is recommended; a stored password lives in its own file outside the ordinary plugin settings, but is still plaintext on disk and readable by any plugin running as you -- see this plugin's README before relying on it."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            width: parent.width
            wrapMode: Text.WordWrap
        }

        // ------------------------------------------------------- add form

        Column {
            width: parent.width
            spacing: Theme.spacingS

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: nameField
                    width: (parent.width - Theme.spacingS) / 2
                    placeholderText: "Name (optional)"
                }

                DankTextField {
                    id: hostField
                    width: (parent.width - Theme.spacingS) / 2
                    placeholderText: "Host or IP"
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: portField
                    width: (parent.width - Theme.spacingS * 2) * 0.25
                    placeholderText: "Port"
                    text: "22"
                }

                DankTextField {
                    id: usernameField
                    width: (parent.width - Theme.spacingS * 2) * 0.35
                    placeholderText: "Username"
                }

                DankDropdown {
                    width: (parent.width - Theme.spacingS * 2) * 0.4
                    text: ""
                    currentValue: root.newAuthMethod === "password" ? "Password" : "Key (recommended)"
                    options: ["Key (recommended)", "Password"]
                    onValueChanged: newValue => {
                        root.newAuthMethod = newValue === "Password" ? "password" : "key";
                    }
                }
            }

            DankTextField {
                id: identityFileField
                width: parent.width
                visible: root.newAuthMethod === "key"
                placeholderText: "Identity file (optional, e.g. ~/.ssh/id_ed25519)"
            }

            DankTextField {
                id: passwordField
                width: parent.width
                visible: root.newAuthMethod === "password"
                placeholderText: "Password (optional -- leave blank to type it at connect time)"
                echoMode: TextInput.Password
                showPasswordToggle: true
            }

            DankButton {
                width: 100
                height: 36
                text: I18n.tr("Add host")
                onClicked: {
                    root.addHost(nameField.text, hostField.text, portField.text, usernameField.text, identityFileField.text, passwordField.text);
                    nameField.text = "";
                    hostField.text = "";
                    portField.text = "22";
                    usernameField.text = "";
                    identityFileField.text = "";
                    passwordField.text = "";
                    root.newAuthMethod = "key";
                }
            }
        }

        // ---------------------------------------------------------- list

        StyledText {
            text: I18n.tr("Current Hosts")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            visible: root.hosts.length > 0
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS

            Repeater {
                model: root.hosts

                Column {
                    id: rowDelegate
                    required property int index
                    required property var modelData
                    width: parent.width
                    spacing: Theme.spacingXS

                    StyledRect {
                        width: parent.width
                        height: 52
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                        border.width: 0

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: buttonRow.left
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            Column {
                                width: parent.width
                                spacing: 2

                                StyledText {
                                    text: rowDelegate.modelData.name || rowDelegate.modelData.host
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                    width: parent.width
                                }

                                StyledText {
                                    text: {
                                        const h = rowDelegate.modelData;
                                        const dest = (h.username ? h.username + "@" : "") + h.host + (h.port && h.port !== "22" ? ":" + h.port : "");
                                        const auth = h.authMethod === "password" ? (h.hasPassword ? "password stored" : "password, not stored") : (h.identityFile ? "key: " + h.identityFile : "key, default identity");
                                        return dest + " · " + auth;
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }
                        }

                        Row {
                            id: buttonRow
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            Rectangle {
                                visible: rowDelegate.modelData.authMethod === "password"
                                width: 96
                                height: 28
                                radius: Theme.cornerRadius
                                color: pwArea.containsMouse ? Theme.primaryHover : Theme.primary

                                StyledText {
                                    anchors.centerIn: parent
                                    text: rowDelegate.modelData.hasPassword ? I18n.tr("Change pw") : I18n.tr("Set password")
                                    color: Theme.onPrimary
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                }

                                MouseArea {
                                    id: pwArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        pwEditField.text = "";
                                        root.editingPasswordIndex = (root.editingPasswordIndex === rowDelegate.index) ? -1 : rowDelegate.index;
                                    }
                                }
                            }

                            Rectangle {
                                width: 70
                                height: 28
                                color: removeArea.containsMouse ? Theme.errorHover : Theme.error
                                radius: Theme.cornerRadius

                                StyledText {
                                    anchors.centerIn: parent
                                    text: I18n.tr("Remove")
                                    color: Theme.onError
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                }

                                MouseArea {
                                    id: removeArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (root.editingPasswordIndex === rowDelegate.index)
                                            root.editingPasswordIndex = -1;
                                        root.removeHost(rowDelegate.modelData.id);
                                    }
                                }
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: root.editingPasswordIndex === rowDelegate.index

                        DankTextField {
                            id: pwEditField
                            width: parent.width - 160
                            placeholderText: "New password"
                            echoMode: TextInput.Password
                            showPasswordToggle: true
                        }

                        DankButton {
                            width: 70
                            height: 36
                            text: I18n.tr("Save")
                            onClicked: root.savePasswordFor(rowDelegate.modelData.id, pwEditField.text)
                        }

                        DankButton {
                            width: 80
                            height: 36
                            text: I18n.tr("Clear pw")
                            visible: rowDelegate.modelData.hasPassword
                            onClicked: root.savePasswordFor(rowDelegate.modelData.id, "")
                        }
                    }
                }
            }

            StyledText {
                text: I18n.tr("No hosts added yet")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                visible: root.hosts.length === 0
            }
        }
    }
}
