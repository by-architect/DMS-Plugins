pragma Singleton

import QtQuick

// Only what QuickNotesCard and TaskRow read from DMS's Theme, for the tests.
QtObject {
    property real spacingXS: 4
    property real spacingS: 8
    property real spacingM: 12
    property real spacingL: 16
    property real cornerRadius: 12
    property int fontSizeSmall: 12
    property int fontSizeMedium: 14
    property int fontSizeLarge: 16
    property string fontFamily: "sans-serif"
    property color primary: "#6750a4"
    property color surfaceText: "#1c1b1f"
    property color surfaceVariantText: "#49454f"
    property color surfaceContainer: "#f3edf7"
    property color surfaceContainerHigh: "#ece6f0"
    property color surfaceHover: "#e8def8"
    property color outline: "#79747e"
    property color outlineMedium: "#a09ba8"
    property color error: "#b3261e"
    property color background: "#fffbfe"

    function withAlpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }
}
