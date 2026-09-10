import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "clipboard.js" as Clipboard
import "presets.js" as Presets

// The action list, grouped by what kind of clipboard content an action is for.
//
// The stock ListSettingWithInput can only hold flat rows of text fields, and an
// action is not flat -- it carries a list of filters, each with its own
// operator. So the editor below is built from plain qs.Widgets pieces, and
// writes through PluginSettings.saveValue like every other setting here.
PluginSettings {
    id: root

    pluginId: "clipboardRunner"

    // Read through SettingsData rather than loadValue(): this one re-evaluates
    // when the stored settings change, so the list redraws itself after every
    // edit without any manual refresh.
    function allActions() {
        const stored = SettingsData.getPluginSetting(root.pluginId, "actions", []);
        return Array.isArray(stored) ? stored : [];
    }

    // Rows carry their index into the flat stored list, because that is what
    // every mutation below addresses.
    function actionsIn(group) {
        const all = allActions();
        const out = [];
        for (var i = 0; i < all.length; i++) {
            if ((all[i].group || "text") === group)
                out.push({
                    "action": all[i],
                    "index": i
                });
        }
        return out;
    }

    function _write(next) {
        root.saveValue("actions", next);
    }

    function _clone() {
        return JSON.parse(JSON.stringify(allActions()));
    }

    function addAction(group) {
        const next = _clone();
        next.push({
            "enabled": true,
            "name": "",
            "icon": "",
            "group": group,
            "extensions": "",
            "conditions": [],
            "command": ""
        });
        _write(next);
    }

    function updateActionField(index, key, value) {
        const next = _clone();
        if (index < 0 || index >= next.length)
            return;
        next[index][key] = value;
        _write(next);
    }

    function removeAction(index) {
        const next = _clone();
        if (index < 0 || index >= next.length)
            return;
        next.splice(index, 1);
        _write(next);
    }

    function addCondition(index) {
        const next = _clone();
        if (index < 0 || index >= next.length)
            return;
        const conditions = next[index].conditions || [];
        conditions.push({
            "op": "includes",
            "value": "",
            "caseSensitive": false
        });
        next[index].conditions = conditions;
        _write(next);
    }

    function updateConditionField(index, conditionIndex, key, value) {
        const next = _clone();
        if (index < 0 || index >= next.length)
            return;
        const conditions = next[index].conditions || [];
        if (conditionIndex < 0 || conditionIndex >= conditions.length)
            return;
        conditions[conditionIndex][key] = value;
        next[index].conditions = conditions;
        _write(next);
    }

    function removeCondition(index, conditionIndex) {
        const next = _clone();
        if (index < 0 || index >= next.length)
            return;
        const conditions = next[index].conditions || [];
        if (conditionIndex < 0 || conditionIndex >= conditions.length)
            return;
        conditions.splice(conditionIndex, 1);
        next[index].conditions = conditions;
        _write(next);
    }

    Component.onCompleted: Presets.seedIfNeeded(pluginService, pluginId)
    onPluginServiceChanged: Presets.seedIfNeeded(pluginService, pluginId)

    // Puts back only the shipped actions that are no longer in the list, so an
    // edited one is left as you edited it.
    function restoreBuiltins() {
        const result = Presets.restoreMissing(allActions());
        if (result.added === 0) {
            ToastService.showInfo("Nothing to restore", "Every built-in action is already in the list");
            return;
        }
        _write(result.actions);
        ToastService.showInfo("Restored " + result.added + (result.added === 1 ? " action" : " actions"), "");
    }

    function groupBlurb(group) {
        if (group === "url")
            return "For links: http, https, mailto, magnet, or a bare www address.";
        if (group === "color")
            return "For colours: #rgb, #rrggbb, #rrggbbaa, rgb(...) or hsl(...).";
        if (group === "path")
            return "For filesystem paths and file:// URIs. Narrow further by extension below.";
        return "For everything that is not a link, a colour or a path.";
    }

    function commandPlaceholder(group) {
        if (group === "url")
            return "yt-dlp ${clipboard}";
        if (group === "color")
            return "notify-send Colour ${color}";
        if (group === "path")
            return "mpv ${path}";
        return "notify-send Clipboard ${clipboard}";
    }

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Prefix that activates the launcher. The trailing space keeps unrelated words from matching."
        placeholder: "clip "
        defaultValue: "clip "
    }

    StringSetting {
        settingKey: "downloadDir"
        label: "Downloads folder"
        description: "Where ${downloads} points. Downloads, clones and saved swatches land here."
        placeholder: "/home/neo/Downloads"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "terminal"
        label: "Terminal"
        description: "Only used by the actions that open an editor, since nvim cannot run without a window. Everything else runs in the background with no terminal at all."
        placeholder: "ghostty -e"
        defaultValue: "ghostty -e"
    }

    StyledText {
        width: parent ? parent.width : 0
        topPadding: Theme.spacingM
        text: "Actions"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent ? parent.width : 0
        text: "Nothing here runs by itself. Type the trigger in the launcher and only the actions that fit what you copied are offered. Clipboard text reaches the command as an argument, so a copied semicolon stays part of the text instead of starting a second command."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    DankButton {
        text: "Restore built-in actions"
        iconName: "restart_alt"
        onClicked: root.restoreBuiltins()
    }

    Repeater {
        model: Clipboard.GROUPS

        Column {
            id: groupSection

            required property var modelData

            width: parent ? parent.width : 0
            topPadding: Theme.spacingM
            spacing: Theme.spacingS

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: groupSection.modelData.icon
                    size: Theme.iconSizeSmall
                    color: Theme.primary
                }

                StyledText {
                    id: groupTitle
                    anchors.verticalCenter: parent.verticalCenter
                    text: groupSection.modelData.label
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }

                Item {
                    width: Math.max(0, parent.width - groupTitle.implicitWidth - Theme.iconSizeSmall - addActionButton.width - Theme.spacingS * 3)
                    height: 1
                }

                DankActionButton {
                    id: addActionButton
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 28
                    iconName: "add"
                    iconSize: 18
                    iconColor: Theme.primary
                    onClicked: root.addAction(groupSection.modelData.id)
                }
            }

            StyledText {
                width: parent.width
                text: root.groupBlurb(groupSection.modelData.id)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            StyledText {
                width: parent.width
                visible: root.actionsIn(groupSection.modelData.id).length === 0
                text: "Nothing yet."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                font.italic: true
            }

            Repeater {
                model: root.actionsIn(groupSection.modelData.id)

                Rectangle {
                    id: actionCard

                    required property var modelData

                    readonly property var action: modelData.action
                    readonly property int actionIndex: modelData.index
                    readonly property string group: groupSection.modelData.id

                    width: groupSection.width
                    height: actionColumn.implicitHeight + Theme.spacingM
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: actionColumn
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            DankTextField {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - iconField.width - enableToggle.width - removeButton.width - Theme.spacingS * 3
                                text: actionCard.action.name || ""
                                font.pixelSize: Theme.fontSizeSmall
                                placeholderText: "Name"
                                onEditingFinished: root.updateActionField(actionCard.actionIndex, "name", text)
                            }

                            DankTextField {
                                id: iconField
                                anchors.verticalCenter: parent.verticalCenter
                                width: 130
                                text: actionCard.action.icon || ""
                                font.pixelSize: Theme.fontSizeSmall
                                placeholderText: "material:bolt"
                                onEditingFinished: root.updateActionField(actionCard.actionIndex, "icon", text)
                            }

                            DankToggle {
                                id: enableToggle
                                anchors.verticalCenter: parent.verticalCenter
                                width: 40
                                height: 24
                                hideText: true
                                checked: actionCard.action.enabled !== false
                                onToggled: checked => root.updateActionField(actionCard.actionIndex, "enabled", checked)
                            }

                            DankActionButton {
                                id: removeButton
                                anchors.verticalCenter: parent.verticalCenter
                                buttonSize: 28
                                iconName: "delete"
                                iconSize: 18
                                iconColor: Theme.error
                                onClicked: root.removeAction(actionCard.actionIndex)
                            }
                        }

                        DankTextField {
                            width: parent.width
                            visible: actionCard.group === "path"
                            text: actionCard.action.extensions || ""
                            font.pixelSize: Theme.fontSizeSmall
                            placeholderText: "Extensions: mp4, mkv, webm — empty means any"
                            onEditingFinished: root.updateActionField(actionCard.actionIndex, "extensions", text)
                        }

                        Repeater {
                            model: actionCard.action.conditions || []

                            Row {
                                id: conditionRow

                                required property int index
                                required property var modelData

                                readonly property bool needsValue: (modelData.op || "includes") !== "any"

                                width: actionColumn.width
                                spacing: Theme.spacingS

                                StyledText {
                                    id: conditionLead
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 34
                                    text: conditionRow.index === 0 ? "when" : "and"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                DankDropdown {
                                    id: operatorDropdown
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 150
                                    compactMode: true
                                    dropdownWidth: width
                                    popupWidth: 180
                                    currentValue: Clipboard.operatorLabel(conditionRow.modelData.op || "includes")
                                    options: Clipboard.OPERATORS.map(o => o.label)
                                    onValueChanged: value => root.updateConditionField(actionCard.actionIndex, conditionRow.index, "op", Clipboard.operatorValue(value))
                                }

                                DankTextField {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0, parent.width - conditionLead.width - operatorDropdown.width - caseButton.width - dropConditionButton.width - Theme.spacingS * 4)
                                    enabled: conditionRow.needsValue
                                    opacity: enabled ? 1 : 0.4
                                    text: conditionRow.modelData.value || ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    placeholderText: "youtube.com"
                                    onEditingFinished: root.updateConditionField(actionCard.actionIndex, conditionRow.index, "value", text)
                                }

                                DankActionButton {
                                    id: caseButton
                                    anchors.verticalCenter: parent.verticalCenter
                                    buttonSize: 28
                                    iconName: "match_case"
                                    iconSize: 18
                                    enabled: conditionRow.needsValue
                                    iconColor: conditionRow.modelData.caseSensitive === true ? Theme.primary : Theme.surfaceVariantText
                                    onClicked: root.updateConditionField(actionCard.actionIndex, conditionRow.index, "caseSensitive", conditionRow.modelData.caseSensitive !== true)
                                }

                                DankActionButton {
                                    id: dropConditionButton
                                    anchors.verticalCenter: parent.verticalCenter
                                    buttonSize: 28
                                    iconName: "close"
                                    iconSize: 18
                                    iconColor: Theme.surfaceVariantText
                                    onClicked: root.removeCondition(actionCard.actionIndex, conditionRow.index)
                                }
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            StyledText {
                                id: filterHint
                                anchors.verticalCenter: parent.verticalCenter
                                text: (actionCard.action.conditions || []).length === 0 ? "No filter — every " + groupSection.modelData.label.toLowerCase() + " matches" : "All filters must match"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                font.italic: true
                            }

                            DankActionButton {
                                id: addConditionButton
                                anchors.verticalCenter: parent.verticalCenter
                                buttonSize: 24
                                iconName: "add"
                                iconSize: 14
                                iconColor: Theme.surfaceVariantText
                                onClicked: root.addCondition(actionCard.actionIndex)
                            }
                        }

                        DankTextField {
                            width: parent.width
                            text: actionCard.action.command || ""
                            font.pixelSize: Theme.fontSizeSmall
                            placeholderText: root.commandPlaceholder(actionCard.group)
                            onEditingFinished: root.updateActionField(actionCard.actionIndex, "command", text)
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            DankToggle {
                                id: notifyToggle
                                anchors.verticalCenter: parent.verticalCenter
                                width: 40
                                height: 24
                                hideText: true
                                checked: actionCard.action.notify !== false
                                onToggled: checked => root.updateActionField(actionCard.actionIndex, "notify", checked)
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - notifyToggle.width - Theme.spacingS
                                text: "Notify when it finishes — worth it for anything slow, noise for anything instant"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }
                        }

                        StyledText {
                            width: parent.width
                            text: Clipboard.placeholderHint(actionCard.group)
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }
        }
    }
}
