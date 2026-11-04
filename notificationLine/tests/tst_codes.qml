import QtQuick
import QtTest
import "../codes.js" as Codes

// Which notifications have a one-time code in them, and which number it is.
TestCase {
    name: "Codes"

    function test_codes() {
        compare(Codes.find("Messages", "Your verification code is 482913"), "482913");
        compare(Codes.find("Garanti BBVA", "Doğrulama kodunuz: 482913. Kimseyle paylaşmayın."), "482913");
        compare(Codes.find("+90 850 222 0 333", "Tek kullanımlık şifreniz 48291 olup 3 dk geçerlidir."), "48291", "five digits");
        compare(Codes.find("Google", "G-482913 is your Google verification code."), "482913", "Google's G- prefix");
        compare(Codes.find("WhatsApp", "Your WhatsApp code: 482-913"), "482913", "written in two halves");
        compare(Codes.find("Steam", "Login code 482 913"), "482913");
        compare(Codes.find("Your code", "482913"), "482913", "the word in the title");
        compare(Codes.find("e-Devlet", "<b>482913</b> e-Devlet giriş şifrenizdir"), "482913", "markup and the word after it");
    }

    function test_nearestToTheWord() {
        compare(Codes.find("Bank", "Card ending 554433 · OTP 482913 for 12.345 TL"), "482913");
        compare(Codes.find("Amazon", "Your one-time password is 482913. Order 778899 ships today."), "482913");
    }

    function test_notCodes() {
        compare(Codes.find("Ada", "see you at 10:30"), "");
        compare(Codes.find("Bank", "Your code: 1234567"), "", "seven digits");
        compare(Codes.find("Bank", "Your code: 1234"), "", "four digits");
        compare(Codes.find("Bank", "OTP for ₺123456 payment"), "", "money in front");
        compare(Codes.find("Bank", "OTP for 123456 TL payment"), "", "money after");
        compare(Codes.find("Bank", "OTP for 12.345,67 payment"), "", "a decimal");
        compare(Codes.find("Shop", "Order code #123456 shipped"), "", "a reference");
        compare(Codes.find("Ada", "my code is +90 532 123 45 67"), "", "a phone number");
        compare(Codes.find("Ada", "kod +905321234567"), "");
        compare(Codes.find("Ada", "invoice-123456 code"), "", "part of a name");
        compare(Codes.find("Ada", "code abc123456"), "");
        compare(Codes.find("Ada", "progress code: 99.5% 123456%"), "");
        compare(Codes.find("Ada", ""), "");
    }

    function test_needsAWord() {
        compare(Codes.find("Ada", "order 482913 is on its way"), "", "no code word");
        compare(Codes.find("Ada", "order 482913 is on its way", true), "482913", "any number, when asked");
        compare(Codes.find("Ada", "482913 or 554433?", true), "", "but not when there are two");
    }
}
