import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

// Sign-in for a provider that is waiting to be linked.
//
// Which of the three forms is shown follows what the bridge asked for: a QR to
// scan, a code to type elsewhere, or a URL to open. Rendering the QR is done by
// the backend so no bridge author has to produce an image.
Item {
    id: root

    // The chat core, handed down from the plugin daemon. It was a shell
    // singleton before this became a plugin, which is why it used to be
    // reachable from anywhere without being passed.
    //
    // Deliberately not called "chat": several of these components already use
    // that name for the conversation being shown, which is a different thing.
    required property var chatCore

    property var provider: null

    readonly property string providerId: provider?.id ?? ""
    readonly property string providerName: provider?.name || providerId
    readonly property string method: provider?.authMethod ?? ""
    readonly property string payload: provider?.authPayload ?? ""

    property string qrImagePath: ""
    property bool requesting: false

    // A provider that signs in with typed details -- a Matrix homeserver, a
    // user and a password -- asks with a form: its own title, and the fields
    // it needs, which are drawn here as it described them. The window had no
    // way to show one, so such a provider sat behind a "Start sign-in" button
    // that asked it for the very form it had already sent.
    readonly property var formFields: provider?.authFields ?? []
    readonly property string formTitle: provider?.authTitle ?? ""
    property var formValues: ({})
    property bool submitting: false
    property string formError: ""

    readonly property bool formComplete: {
        if (root.formFields.length === 0)
            return false;
        for (let i = 0; i < root.formFields.length; i++) {
            const field = root.formFields[i];
            if (field.required && String(root.formValues[field.key] ?? "").trim() === "")
                return false;
        }
        return true;
    }

    // Each form starts from the values the provider filled in itself.
    onFormFieldsChanged: root.resetForm()

    function resetForm() {
        const values = {};
        for (let i = 0; i < root.formFields.length; i++)
            values[root.formFields[i].key] = root.formFields[i].value || "";
        root.formValues = values;
        root.formError = "";
    }

    function setFormValue(key, value) {
        const next = Object.assign({}, root.formValues);
        next[key] = value;
        root.formValues = next;
    }

    // The values go to the provider and nowhere else. A password is not kept
    // here past the attempt, whichever way it goes: what was typed is gone
    // from the form the moment the answer arrives.
    function submitForm() {
        if (!root.formComplete || root.submitting)
            return;
        root.submitting = true;
        root.formError = "";

        const values = Object.assign({}, root.formValues);
        root.chatCore.authSubmit(root.providerId, values, (succeeded, error) => {
            root.submitting = false;
            const kept = Object.assign({}, root.formValues);
            for (let i = 0; i < root.formFields.length; i++) {
                if (root.formFields[i].type === "password")
                    kept[root.formFields[i].key] = "";
            }
            root.formValues = kept;
            if (!succeeded)
                root.formError = error || I18n.tr("Sign-in failed");
        });
    }

    // Re-render whenever the challenge changes. These rotate on a timer for
    // most services, so a stale image is a sign-in that silently will not work.
    onPayloadChanged: refreshChallenge()
    onVisibleChanged: {
        // Only render if there is nothing to show yet: payloadChanged already
        // covers rotation, and rendering on every visibility flip meant two
        // concurrent requests racing over the same output file.
        if (visible && root.qrImagePath === "")
            refreshChallenge();
    }

    function refreshChallenge() {
        root.qrImagePath = "";
        if (!visible || root.providerId === "" || root.payload === "")
            return;
        if (root.method !== "qr")
            return;

        root.requesting = true;
        root.chatCore.link.sendRequest("chat.authQrCode", {
            "provider": root.providerId
        }, response => {
            root.requesting = false;
            if (response.error) {
                root.chatCore.log.warn("could not render sign-in code:", response.error);
                return;
            }
            root.qrImagePath = response.result?.path || "";
        });
    }

    Column {
        anchors.centerIn: parent
        width: Math.min(360, parent.width - Theme.spacingXL * 2)
        spacing: Theme.spacingM

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: I18n.tr("Sign in to %1").arg(root.providerName)
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
            wrapMode: Text.WordWrap
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            text: {
                switch (root.method) {
                case "qr":
                    return I18n.tr("Scan this code with the app on your phone.");
                case "code":
                    return I18n.tr("Enter this code in the app on your other device.");
                case "url":
                    return I18n.tr("Open this link to finish signing in.");
                case "form":
                    return root.formTitle !== "" ? root.formTitle : I18n.tr("Enter your account details.");
                default:
                    return I18n.tr("Start sign-in to link this device.");
                }
            }
        }

        // ------------------------------------------------------------ QR

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.method === "qr"
            width: 220
            height: 220

            // White plate behind the code: scanners need the contrast, and a
            // transparent code on a dark surface often will not read.
            StyledRect {
                anchors.fill: parent
                radius: Theme.cornerRadius
                color: "white"
                visible: qrImage.status === Image.Ready
            }

            Image {
                id: qrImage
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                smooth: false
                mipmap: false
                // No cache: the payload rotates, and a cached pixmap would keep
                // showing a code that has already expired.
                cache: false
                source: root.qrImagePath !== "" ? "file://" + root.qrImagePath : ""
            }

            DankSpinner {
                anchors.centerIn: parent
                width: 32
                height: 32
                visible: root.requesting || (root.qrImagePath !== "" && qrImage.status === Image.Loading)
            }
        }

        // ---------------------------------------------------------- code

        StyledRect {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.method === "code" && root.payload !== ""
            width: codeText.implicitWidth + Theme.spacingXL * 2
            height: codeText.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            StyledText {
                id: codeText
                anchors.centerIn: parent
                text: root.payload
                font.pixelSize: Theme.fontSizeLarge
                font.family: Theme.monoFontFamily
                font.letterSpacing: 2
                color: Theme.surfaceText
            }
        }

        // ----------------------------------------------------------- url

        DankButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.method === "url" && root.payload !== ""
            text: I18n.tr("Open sign-in page")
            iconName: "open_in_new"
            backgroundColor: Theme.primary
            textColor: Theme.onPrimary
            onClicked: Quickshell.execDetached(["xdg-open", root.payload])
        }

        // ---------------------------------------------------------- form

        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: root.method === "form"

            Repeater {
                id: formRepeater

                model: root.method === "form" ? root.formFields : []

                delegate: DankTextField {
                    id: formField

                    required property var modelData
                    required property int index

                    width: parent.width
                    labelText: (modelData.label || modelData.key) + (modelData.required ? " *" : "")
                    placeholderText: modelData.placeholder || ""
                    echoMode: modelData.type === "password" ? TextInput.Password : TextInput.Normal
                    showPasswordToggle: modelData.type === "password"
                    enabled: !root.submitting

                    // Written back as typed, and set from the form when it
                    // changes a field itself -- clearing the password after an
                    // attempt. Not a binding: typing into a field drops its
                    // binding, and the password would then stay on screen.
                    Component.onCompleted: formField.text = root.formValues[modelData.key] ?? ""
                    onTextChanged: {
                        if (formField.text !== (root.formValues[modelData.key] ?? ""))
                            root.setFormValue(modelData.key, formField.text);
                    }

                    Connections {
                        target: root

                        function onFormValuesChanged() {
                            const value = root.formValues[formField.modelData.key] ?? "";
                            if (formField.text !== value)
                                formField.text = value;
                        }
                    }

                    // Enter moves to the next field, and on the last signs in.
                    onAccepted: {
                        const next = formRepeater.itemAt(formField.index + 1);
                        if (next)
                            next.forceActiveFocus();
                        else
                            root.submitForm();
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: root.formError !== ""
                text: root.formError
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
            }

            DankButton {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.submitting ? I18n.tr("Signing in…") : I18n.tr("Sign in")
                iconName: "login"
                backgroundColor: Theme.primary
                textColor: Theme.onPrimary
                enabled: root.formComplete && !root.submitting
                onClicked: root.submitForm()
            }
        }

        // Offered for everything but a form, which has its own button: a
        // challenge may have expired, and asking again is the only way forward.
        DankButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.method !== "form"
            text: root.payload === "" ? I18n.tr("Start sign-in") : I18n.tr("Get a new code")
            iconName: "refresh"
            backgroundColor: root.payload === "" ? Theme.primary : "transparent"
            textColor: root.payload === "" ? Theme.onPrimary : Theme.surfaceText
            onClicked: root.chatCore.login(root.providerId)
        }
    }
}
