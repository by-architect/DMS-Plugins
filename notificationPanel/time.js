.pragma library

function relTime(ms) {
    if (!ms || isNaN(ms))
        return "";
    var delta = Date.now() - ms;
    if (delta < 0)
        delta = 0;
    var s = Math.floor(delta / 1000);
    if (s < 45)
        return "just now";
    var m = Math.floor(s / 60);
    if (m < 60)
        return m + (m === 1 ? " minute ago" : " minutes ago");
    var h = Math.floor(m / 60);
    if (h < 24)
        return h + (h === 1 ? " hour ago" : " hours ago");
    var d = Math.floor(h / 24);
    if (d < 30)
        return d + (d === 1 ? " day ago" : " days ago");
    var mo = Math.floor(d / 30);
    if (mo < 12)
        return mo + (mo === 1 ? " month ago" : " months ago");
    var y = Math.floor(mo / 12);
    return y + (y === 1 ? " year ago" : " years ago");
}

function fmtAbs(ms) {
    if (!ms || isNaN(ms))
        return "";
    var d = new Date(ms);
    function p(n) {
        return n < 10 ? "0" + n : "" + n;
    }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " + p(d.getHours()) + ":" + p(d.getMinutes());
}
