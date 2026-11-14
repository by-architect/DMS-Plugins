import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "view.js" as View

// The Nextcloud account and how the list behaves. The app password is the
// one thing not kept with the other settings: it goes to the daemon, which
// writes it to a file of its own (see QuickNotesService.qml), and it is
// never shown here again once saved -- only whether one is stored.
PluginSettings {
    id: root

    pluginId: "quickNotes"

    readonly property var service: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        const daemon = instances["quickNotes"] ?? null;
        return daemon ? daemon.service : null;
    }

    property real nowMs: Date.now()

    function savePassword() {
        if (passwordField.text.length === 0)
            return;
        if (!root.service) {
            ToastService.showWarning("Password not saved", "Enable the Quick Notes plugin first.");
            return;
        }
        root.service.setPassword(passwordField.text);
        passwordField.text = "";
    }

    Timer {
        interval: 5000
        repeat: true
        running: root.visible
        onTriggered: root.nowMs = Date.now()
    }

    StyledText {
        width: parent.width
        text: "Bind dms ipc call quickNotes toggle to a key under Settings → Keybinds → Add → Spawn to open the window. Tasks typed there show at once and reach Nextcloud in the background; the list is read again on the timer below, never while you wait."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "server"
        label: "Nextcloud address"
        description: "Where your Nextcloud is, e.g. https://cloud.example.com — or the link of one list, copied from Nextcloud Tasks or Calendar (… → Copy private link). Any other CalDAV server works too."
        placeholder: "https://cloud.example.com"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "user"
        label: "User name"
        description: "Your Nextcloud login name."
        placeholder: "neo"
        defaultValue: ""
    }

    // ------------------------------------------------------- app password
    Column {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: "App password"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: "Make one in Nextcloud under Personal settings → Security → Devices & sessions → Create new app password. It is kept in ~/.local/share/DankMaterialShell/plugins/quickNotes/secrets.json (mode 0600), not with these settings, and never shown again." + (root.service && root.service.passwordFile ? " Not used now: the password file below is set." : "")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS

            DankTextField {
                id: passwordField

                width: parent.width - saveButton.width - clearButton.width - Theme.spacingS * 2
                placeholderText: root.service && root.service.hasStoredPassword ? "An app password is stored — type a new one to replace it" : "xxxxx-xxxxx-xxxxx-xxxxx-xxxxx"
                echoMode: TextInput.Password
                showPasswordToggle: true
                onAccepted: root.savePassword()
            }

            DankButton {
                id: saveButton

                width: 90
                height: 36
                text: "Save"
                enabled: passwordField.text.length > 0
                onClicked: root.savePassword()
            }

            DankButton {
                id: clearButton

                width: 90
                height: 36
                text: "Forget"
                visible: !!root.service && root.service.hasStoredPassword
                onClicked: root.service.setPassword("")
            }
        }
    }

    StringSetting {
        settingKey: "passwordFile"
        label: "Password file (optional)"
        description: "Read the app password from this file instead — an agenix or sops-nix secret, say, when these settings live in your Nix config. Read again whenever it changes."
        placeholder: "/run/agenix/nextcloud-app-password"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "listName"
        label: "Task list"
        description: "The Nextcloud Tasks list to use, by name. Capitals do not matter."
        placeholder: "main"
        defaultValue: "main"
    }

    SliderSetting {
        settingKey: "syncMinutes"
        label: "Read the list every"
        description: "How often the list is read from Nextcloud in the background, to pick up what changed elsewhere. Your own changes do not wait for this: each is sent a moment after you make it."
        defaultValue: 5
        minimum: 1
        maximum: 60
        unit: " min"
        leftIcon: "sync"
    }

    SelectionSetting {
        settingKey: "keepDoneHours"
        label: "Keep done tasks in the list"
        description: "Done tasks are struck through and go away after this long. A search (/) still finds them, and one you mark stays until the window closes."
        options: [
            {
                label: "For an hour",
                value: "1"
            },
            {
                label: "For a day",
                value: "24"
            },
            {
                label: "For a week",
                value: "168"
            },
            {
                label: "Always",
                value: "-1"
            },
            {
                label: "No, hide them",
                value: "0"
            }
        ]
        defaultValue: "24"
    }

    // ------------------------------------------------------------- status
    Column {
        width: parent.width
        spacing: Theme.spacingS

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.outline
            opacity: 0.3
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS

            DankIcon {
                readonly property var line: root.service ? View.syncLine(root.service.status, root.service.configured, root.nowMs) : null

                name: !line ? "power_off" : line.error ? "error" : root.service.syncing ? "sync" : "cloud_done"
                size: 18
                color: line && line.error ? Theme.error : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                width: parent.width - 18 - syncButton.width - Theme.spacingS * 2
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    const s = root.service;
                    if (!s)
                        return "Enable the plugin to connect.";
                    const line = View.syncLine(s.status, s.configured, root.nowMs).text;
                    if (s.passwordFile && s.passwordFileError)
                        return "Password file: " + s.passwordFileError + ". " + line;
                    return (s.status.listUrl ? "“" + s.listTitle + "” · " : "") + line;
                }
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                wrapMode: Text.WordWrap
            }

            DankButton {
                id: syncButton

                width: 110
                height: 36
                text: "Sync now"
                enabled: !!root.service && root.service.configured
                onClicked: root.service.syncNow()
            }
        }
    }
}
