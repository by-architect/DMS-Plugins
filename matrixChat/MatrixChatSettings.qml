import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Whatever these save is handed to the bridge in its `configure` call, and again
// on every change. The bridge never reads this file, or any other shell config,
// which is what lets it be run and debugged outside DMS.
//
// Nothing here is a credential. The homeserver, user id and password are asked
// for by the chat window's sign-in panel (or ./login.sh), exchanged for an
// access token, and only the token is kept — in ~/.local/share/dms-matrix,
// readable by its owner alone.
PluginSettings {
    id: root

    pluginId: "matrixChat"

    // The live chat core, owned by the chat manager plugin's daemon surface --
    // the only thing holding a connection to the bridge. This used to be a
    // ChatService singleton in a forked shell; stock DMS has none, and calling
    // it threw before the recovery key ever left this page.
    readonly property var chat: {
        const instances = root.pluginService?.pluginDaemonInstances ?? ({});
        return instances["chatManager"]?.chat ?? null;
    }

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

    // The account, as the bridge describes it: who is signed in, the device,
    // and whether it is verified. Nothing streams state to this page, so it is
    // read again every few seconds while the page is open -- signing in from
    // the chat window, verifying below, and signing out all change it.
    readonly property var provider: root.chat ? root.chat.providerById("matrixChat") : null
    readonly property var account: root.provider?.account ?? null
    readonly property bool signedIn: (root.account?.userId ?? "") !== ""

    // Connected is signed in, whatever the account says -- a chat manager not
    // rebuilt since this page learned to show the account says nothing at all.
    readonly property bool canSignOut: root.signedIn || (root.provider?.enabled === true && root.provider?.state === "connected")

    property bool confirmingSignOut: false
    property bool clearHistoryOnSignOut: false

    Timer {
        interval: 4000
        repeat: true
        triggeredOnStart: true
        running: root.chat !== null && typeof root.chat.refreshProviders === "function"
        onTriggered: root.chat.refreshProviders()
    }

    function accountSummary() {
        if (!root.chat || !root.chat.available)
            return "The chat manager is not running, so there is no account to show.";
        if (!root.provider || !root.provider.enabled)
            return "Matrix Chat is switched off.";
        if (!root.signedIn) {
            if (root.provider.state === "needsLogin")
                return "Not signed in. Open the chat window to sign in, or run ./login.sh from this plugin's folder.";
            return root.provider.state === "connected" ? "Signed in." : "Connecting…";
        }
        return "Signed in as " + root.account.userId;
    }

    function accountDetails() {
        if (!root.signedIn)
            return "";
        const parts = [];
        if (root.account.homeserver)
            parts.push(root.account.homeserver);
        if (root.account.deviceId)
            parts.push("device " + root.account.deviceId);
        return parts.join("  ·  ");
    }

    function trustSummary() {
        if (!root.signedIn)
            return "";
        if (root.account.encryption === false)
            return "Encryption is not working on this device: encrypted rooms can be neither read nor written to. The chat manager's log says why.";
        let text = root.account.verified ? "This device is verified." : "This device is not verified yet, so other people's devices may not share their keys with it, and older encrypted messages stay unreadable. Verify it with your recovery key below.";
        if (root.account.verified && root.account.keyBackup)
            text += " Your key backup is connected: keys your other devices save reach this one too.";
        const waiting = root.account.waitingForKeys ?? 0;
        if (waiting > 0)
            text += " " + waiting + (waiting === 1 ? " message is" : " messages are") + " waiting for keys.";
        return text;
    }

    function signOut() {
        root.confirmingSignOut = false;
        if (!root.chat)
            return;
        root.chat.logout("matrixChat");
        if (root.clearHistoryOnSignOut)
            root.chat.purge("matrixChat");
        root.clearHistoryOnSignOut = false;
    }

    // ------------------------------------------------------------- account

    StyledText {
        width: parent ? parent.width : 0
        text: "Account"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent ? parent.width : 0
        text: root.accountSummary()
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent ? parent.width : 0
        visible: text !== ""
        text: root.accountDetails()
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WrapAnywhere
    }

    StyledText {
        width: parent ? parent.width : 0
        visible: text !== ""
        text: root.trustSummary()
        font.pixelSize: Theme.fontSizeSmall
        color: root.signedIn && (root.account.encryption === false || !root.account.verified) ? Theme.warning : Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    DankButton {
        visible: root.canSignOut && !root.confirmingSignOut
        text: "Sign out"
        iconName: "logout"
        backgroundColor: "transparent"
        textColor: Theme.error
        onClicked: root.confirmingSignOut = true
    }

    // Signing out is not undone by signing in again: it is a new device then,
    // which starts without the keys this one holds. So it asks first.
    StyledText {
        width: parent ? parent.width : 0
        visible: root.confirmingSignOut
        text: "Sign out of " + (root.account?.userId ?? "Matrix") + " on this computer? This device is removed from your account, along with the keys it holds: signing in again is a new device, which has to be verified again to read encrypted history."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceText
        wrapMode: Text.WordWrap
    }

    DankToggle {
        width: parent ? parent.width : 0
        visible: root.confirmingSignOut
        text: "Also delete Matrix messages stored here"
        description: "Off keeps the conversations already received in the chat history, readable but no longer updated."
        checked: root.clearHistoryOnSignOut
        onToggled: checked => root.clearHistoryOnSignOut = checked
    }

    Row {
        visible: root.confirmingSignOut
        spacing: Theme.spacingS

        DankButton {
            text: "Cancel"
            backgroundColor: "transparent"
            textColor: Theme.surfaceText
            onClicked: {
                root.confirmingSignOut = false;
                root.clearHistoryOnSignOut = false;
            }
        }

        DankButton {
            text: "Sign out"
            iconName: "logout"
            backgroundColor: Theme.error
            textColor: Theme.onPrimary
            onClicked: root.signOut()
        }
    }

    // Verification goes to the bridge and nowhere else. The key is not written
    // to plugin settings, which is ordinary readable config -- the bridge uses
    // it to unlock secret storage and drops it.
    function verify() {
        const key = recoveryKeyField.text.trim();
        if (key === "" || root.verifying)
            return;

        // Said here rather than left to the call: authSubmit returns without
        // ever answering when the manager is not connected, which would leave
        // the button reading "Verifying…" for good.
        if (!root.chat || !root.chat.available) {
            root.verifyFailed = true;
            root.verifyResult = "The chat manager is not running, so there is nothing to verify with. Enable the Chat Manager plugin, sign in to Matrix, then try again.";
            return;
        }

        root.verifying = true;
        root.verifyResult = "";

        root.chat.authSubmit("matrixChat", {
            "recoveryKey": key
        }, (succeeded, error) => {
            root.verifying = false;
            root.verifyFailed = !succeeded;
            if (succeeded) {
                // Clear on success so the key is not left sitting in the field.
                recoveryKeyField.text = "";
                root.verifyResult = "This device is verified, and your key backup was restored to it if the account has one. Messages it received but could not read yet are being tried again.";
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

    ToggleSetting {
        settingKey: "sendTypingNotifications"
        label: "Send typing notifications"
        description: "Let people see when you are typing to them. Turning this off still shows you when they are typing."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "useMatrixNotifications"
        label: "Follow my Matrix notification settings"
        description: "Rooms you muted or set to mentions only in Element stay quiet here, and a message that mentions you always gets through. Muting a room here mutes it on your other devices too."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showAvatars"
        label: "Show pictures"
        description: "Room and profile pictures, fetched from your homeserver as small thumbnails."
        defaultValue: true
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

        DankToggle {
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
        text: "Matrix has no QR code to scan, so the chat window's sign-in panel asks for your homeserver, user id and password instead — or run ./login.sh from this plugin's folder. What you type is exchanged for an access token and then discarded — only the token is kept, and never in this settings file."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent ? parent.width : 0
        text: "Signing in creates a new device, which cannot read messages sent before it existed. Verifying it below marks it as yours and restores your key backup to it."
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
