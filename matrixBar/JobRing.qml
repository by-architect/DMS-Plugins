import QtQuick
import qs.Common

// rsync or backups on one machine: how many run now in the middle, and a
// ring that says how they stand -- turning while one runs (or filling, when
// its progress is known), red when one failed last time, amber while one
// waits to retry, and empty when there is nothing to tell.
Ring {
    id: root

    property var job: null    // bar.js jobSummary()

    readonly property int count: root.job ? root.job.count : -1
    readonly property bool failed: root.job !== null && root.job.failed.length > 0
    readonly property bool retrying: root.job !== null && root.job.retrying.length > 0

    value: {
        if (!root.job)
            return -1;
        if (root.count > 0)
            return root.job.percent >= 0 ? root.job.percent / 100 : -1;
        return root.failed || root.retrying ? 1 : -1;
    }
    spinning: root.count > 0 && (!root.job || root.job.percent < 0)
    ringColor: root.count > 0 ? Theme.primary : (root.failed ? Theme.error : Theme.warning)
    text: root.count >= 0 ? String(root.count) : "–"
    contentColor: root.count > 0 ? Theme.surfaceText : (root.failed ? Theme.error : Theme.surfaceVariantText)
}
