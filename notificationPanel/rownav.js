.pragma library

// Scrolls just enough to bring row `index` of `repeater` fully into view
// inside `flickable` — a no-op if it's already visible. Used to keep every
// container in sync when Alt+j/k moves one shared row index across all of
// them at once; each container clamps to its own last row if it has fewer
// rows than the shared index.
function scrollRowIntoView(flickable, repeater, index) {
    if (!flickable || !repeater || index < 0)
        return;
    const target = Math.min(index, repeater.count - 1);
    if (target < 0)
        return;
    const item = repeater.itemAt(target);
    if (!item)
        return;

    const itemTop = item.y;
    const itemBottom = item.y + item.height;
    const viewTop = flickable.contentY;
    const viewBottom = flickable.contentY + flickable.height;

    if (itemTop < viewTop) {
        flickable.contentY = Math.max(0, itemTop);
    } else if (itemBottom > viewBottom) {
        const maxY = Math.max(0, flickable.contentHeight - flickable.height);
        flickable.contentY = Math.min(maxY, itemBottom - flickable.height);
    }
}
