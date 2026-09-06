import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Whatever these save is handed to the bridge in its `configure` call, and again
// on every change. The bridge never reads this file, or any other shell config,
// which is what lets it be run and debugged outside DMS.
//
// Nothing here is a credential. The homeserver, user id and password are asked
// for by ./login.sh, exchanged for an access token, and only the token is kept —
// in ~/.local/share/dms-matrix, readable by its owner alone.
PluginSettings {
    id: root

    pluginId: "matrixChat"

    // Matrix's own room categories.
    //
    // Listed here rather than in the shell because they are Matrix's idea:
    // another service has folders, or labels, or nothing at all. The shell only
    // reads the resulting hiddenTags list.
    readonly property var filterTags: [
        {
            "tag": "space",
            "label": "Spaces",
            "description": "Spaces group rooms together; they are containers rather than conversations"
        },
        {
            "tag": "invite",
            "label": "Invitations",
            "description": "Rooms you have been invited to but not joined"
        },
        {
            "tag": "lowPriority",
            "label": "Low priority rooms",
            "description": "Rooms you have marked low priority"
        },
        {
            "tag": "serverNotice",
            "label": "Server notices",
            "description": "Administrative messages from your homeserver"
        },
        {
            "tag": "archived",
            "label": "Archived chats",
            "description": "Conversations you have put away"
        },
        {
            "tag": "muted",
            "label": "Muted chats",
            "description": "Conversations you have silenced"
        },
        {
            "tag": "group",
            "label": "Rooms",
            "description": "Rooms with more than one other person, as opposed to direct messages"
        }
    ]

    property bool verifying: false
    property string verifyResult: ""
    property bool verifyFailed: false

    // Verification goes to the bridge and nowhere else. The key is not written
    // to plugin settings, which is ordinary readable config -- the bridge uses
    // it to unlock secret storage and drops it.
    function verify() {
        const key = recoveryKeyField.text.trim();
        if (key === "" || root.verifying)
            return;

        root.verifying = true;
        root.verifyResult = "";

        ChatService.authSubmit("matrixChat", {
            "recoveryKey": key
        }, (succeeded, error) => {
            root.verifying = false;
            root.verifyFailed = !succeeded;
            if (succeeded) {
                // Clear on success so the key is not left sitting in the field.
                recoveryKeyField.text = "";
                root.verifyResult = "This device is verified. Encrypted history will decrypt as it syncs.";
            } else {
                root.verifyResult = error || "Verification failed.";
            }
        });
    }

    function hiddenTags() {
        return SettingsData.getPluginSetting("matrixChat", "hiddenTags", []) || [];
    }

    function isShown(tag) {
        return hiddenTags().indexOf(tag) === -1;
    }

    function setShown(tag, shown) {
        const current = hiddenTags().slice();
        const at = current.indexOf(tag);

        if (!shown && at === -1)
            current.push(tag);
        else if (shown && at !== -1)
            current.splice(at, 1);
        else
            return;

        SettingsData.setPluginSetting("matrixChat", "hiddenTags", current);
    }

    ToggleSetting {
        settingKey: "sendReadReceipts"
        label: "Send read receipts"
        description: "Let people see when you have read their message. Turning this off still clears your own unread count."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoDownloadMedia"
        label: "Download attachments automatically"
        description: "Fetch images and files as messages arrive, instead of when you open them."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "autoDownloadMaxMB"
        label: "Skip attachments larger than"
        description: "Anything above this is left to download when you open it."
        defaultValue: 16
        minimum: 1
        maximum: 100
        unit: " MB"
    }

    // ------------------------------------------------------------- filters

    StyledText {
        width: parent ? parent.width : 0
        topPadding: Theme.spacingM
        text: "Chat filters"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent ? parent.width : 0
        text: "What appears in the conversation list and the chat runner. Turning something off only hides it — searching still finds it, and nothing is deleted."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Repeater {
        model: root.filterTags

        SettingsToggleRow {
            required property var modelData

            width: parent ? parent.width : 0
            text: "Show " + modelData.label
            description: modelData.description
            checked: root.isShown(modelData.tag)
            onToggled: checked => root.setShown(modelData.tag, checked)
        }
    }

    // ------------------------------------------------------------- signing in

    StyledText {
        width: parent ? parent.width : 0
        topPadding: Theme.spacingM
        text: "Signing in"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent ? parent.width : 0
        text: "Matrix has no QR code to scan, so the sign-in panel asks for your homeserver, user id and password instead. What you type is exchanged for an access token and then discarded — only the token is kept, and never in this settings file."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent ? parent.width : 0
        text: "Signing in creates a new device, which cannot read messages sent before it existed. Verify it below to unlock them."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ------------------------------------------------------- verification

    StyledText {
        width: parent ? parent.width : 0
        topPadding: Theme.spacingM
        text: "Verify this device"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent ? parent.width : 0
        text: "Matrix normally verifies a new device by asking you to confirm it on one you are already signed in to. If this is your only device there is nothing to confirm it from, so use your recovery key instead — the one Element gave you when you turned on Secure Backup. Your passphrase works here too."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    DankTextField {
        id: recoveryKeyField

        width: parent ? parent.width : 0
        placeholderText: "EsTx xxxx xxxx xxxx …"
        // Masked: it decrypts the whole account's history, so it deserves the
        // same treatment as a password rather than sitting readable on screen.
        // The reveal toggle earns its place here -- the key is 48 characters of
        // base58 and a single mistyped one fails with no hint which.
        // The field owns passwordVisible and writes to it on click, so it is
        // read here rather than bound -- binding it would break on the first
        // press, flipping the icon without revealing anything.
        showPasswordToggle: true
        echoMode: passwordVisible ? TextInput.Normal : TextInput.Password
        enabled: !root.verifying
        onAccepted: root.verify()
    }

    DankButton {
        enabled: !root.verifying && recoveryKeyField.text.trim() !== ""
        text: root.verifying ? "Verifying…" : "Verify with recovery key"
        iconName: "verified_user"
        backgroundColor: Theme.primary
        textColor: Theme.onPrimary
        onClicked: root.verify()
    }

    StyledText {
        width: parent ? parent.width : 0
        visible: root.verifyResult !== ""
        text: root.verifyResult
        font.pixelSize: Theme.fontSizeSmall
        color: root.verifyFailed ? Theme.error : Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
