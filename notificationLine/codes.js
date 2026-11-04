.pragma library

.import "format.js" as Format

// Finding the one-time code in a notification -- "Your code is 482913",
// "Doğrulama kodunuz: 482 913", "G-482913 is your Google verification code" --
// so it can go to the clipboard before the line is even read.
//
// Only five and six digits count: what almost every service sends. A number
// is only a code when it stands on its own, so these are not:
//
//   12.345 / 12,345 / 1234567   part of a bigger number
//   10:30 / 04/11/2026          a time, a date
//   ₺123456 / 123456 TL         money
//   +90 532 123 45 67           a phone number
//   #123456 / order-123456      a reference
//
// and, unless `anyNumber` is set, the text has to say it is a code: "code",
// "kod", "şifre", "OTP", "verification", "doğrulama" and the like. That is
// what keeps a chat message with an order number in it off the clipboard.

var codeWord = /\b(code|codes|passcode|otp|pin|password|verification|verify|authenticat\w*|2fa|mfa|one[- ]time|sign[- ]?in|log[- ]?in|security|token)\b|kod|şifre|sifre|parola|doğrulama|dogrulama|onay|giriş|giris|tek kullanımlık|güvenlik|guvenlik/gi;

var currencyAfter = /^\s?(tl|try|₺|\$|usd|eur|€|£|gbp|lira)(?![a-z])/i;
var currencyBefore = /[₺$€£]\s?$/;

// Every number in `text` that could be a code, as { code, at, end }.
function candidates(text) {
    var found = [];
    var re = /(\d{3})[ -](\d{3})|\d+/g;
    var m;
    while ((m = re.exec(text)) !== null) {
        var at = m.index;
        var end = at + m[0].length;
        var split = m[1] !== undefined;
        var digits = split ? m[1] + m[2] : m[0];
        if (digits.length < 5 || digits.length > 6)
            continue;
        if (!_standsAlone(text, at, end, split))
            continue;
        found.push({
            "code": digits,
            "at": at,
            "end": end
        });
    }
    return found;
}

function _isDigit(c) {
    return c >= "0" && c <= "9";
}

function _isWordChar(c) {
    // Letters of the Latin, Greek and Cyrillic alphabets, digits, "_".
    return !!c && /[A-Za-z0-9_\u00C0-\u024F\u0370-\u03FF\u0400-\u04FF]/.test(c);
}

function _standsAlone(text, at, end, split) {
    var b1 = text.charAt(at - 1), b2 = text.charAt(at - 2);
    var a1 = text.charAt(end), a2 = text.charAt(end + 1);

    // Glued to a word or a number: "abc123456", "123456x".
    if (_isWordChar(a1))
        return false;
    // "G-482913" is Google's way of writing a code; any other letter or
    // number in front is part of something else.
    if (_isWordChar(b1))
        return false;
    if (b1 === "-" && _isWordChar(b2) && !/^[A-Z]$/.test(b2))
        return false;
    // A reference, a phone number, a percentage.
    if (b1 === "#" || b1 === "+" || a1 === "%")
        return false;
    // A decimal, a time, a date: 12.345, 10:30:45, 04/11.
    if (".,:/".indexOf(b1) !== -1 && _isDigit(b2))
        return false;
    if (".,:/".indexOf(a1) !== -1 && _isDigit(a2))
        return false;
    // One group of a phone number: "+90 532 123 45 67".
    if ((b1 === " " || b1 === "-") && _isDigit(b2))
        return false;
    if (split && (a1 === " " || a1 === "-") && _isDigit(a2))
        return false;
    // Money.
    if (currencyBefore.test(text.slice(Math.max(0, at - 2), at)))
        return false;
    if (currencyAfter.test(text.slice(end, end + 6)))
        return false;
    return true;
}

// The code in a notification, or "".
//
// With a code word in the text, the number nearest after it wins ("Your code
// is 482913, valid for 300000 ms" is 482913), else the nearest before it
// ("482913 is your code"). Without one, a lone number counts only when
// `anyNumber` is set.
function find(summary, body, anyNumber) {
    var text = Format.oneLine((summary || "") + " · " + (body || ""));
    var list = candidates(text);
    if (list.length === 0)
        return "";

    var words = [];
    var m;
    codeWord.lastIndex = 0;
    while ((m = codeWord.exec(text)) !== null)
        words.push(m.index);

    if (words.length === 0) {
        if (!anyNumber)
            return "";
        var distinct = {};
        var count = 0;
        for (var i = 0; i < list.length; i++) {
            if (!distinct[list[i].code]) {
                distinct[list[i].code] = true;
                count++;
            }
        }
        return count === 1 ? list[0].code : "";
    }

    var best = null, bestGap = Infinity;
    for (var c = 0; c < list.length; c++) {
        for (var w = 0; w < words.length; w++) {
            var gap = list[c].at - words[w];
            // Before the word counts too, at a cost: "482913 is your code".
            var cost = gap >= 0 ? gap : -gap * 2;
            if (cost < bestGap) {
                bestGap = cost;
                best = list[c];
            }
        }
    }
    return best ? best.code : "";
}
