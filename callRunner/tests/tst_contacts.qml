import QtQuick
import QtTest
import "../contacts.js" as Contacts

// What scripts/phone.sh's answer turns into, and what typing finds in it.
// Shaped on a real run on an Android 16 phone, with the people and numbers
// made up.
//
//   qmltestrunner -input tests/tst_contacts.qml
TestCase {
    name: "CallRunner"

    // 14 Nov 2026 at noon here
    readonly property real now: new Date(2026, 10, 14, 12, 0, 0).getTime()

    readonly property string answer: ["Welcome to Nixup", "cr:serial 56853bd8", "cr:c contact_id=12, starred=0, data2=2, data1=+905551112233, display_name=Şükrü Işık", "cr:c contact_id=12, starred=1, data2=2, data1=0555 111 22 33, display_name=Şükrü Işık", "cr:c contact_id=14, starred=0, data2=7, data1=+905552223344, display_name=Ali Yılmaz", "cr:c contact_id=15, starred=0, data2=3, data1=02125550000, display_name=Ender, Office", "cr:c contact_id=16, starred=0, data2=2, data1=NULL, display_name=Nobody", "cr:c contact_id=17, starred=0, data2=2, data1=+905553334455, display_name=Ada", "cr:r date=" + (now - 2 * 3600000) + ", type=3, duration=0, number=+905552223344, name=Ali Yılmaz", "cr:r date=" + (now - 5 * 3600000) + ", type=2, duration=61, number=05551112233, name=NULL", "cr:r date=" + (now - 6 * 3600000) + ", type=1, duration=12, number=+905559990000, name=NULL", "cr:r date=" + (now - 30 * 3600000) + ", type=1, duration=40, number=+905552223344, name=Ali Yılmaz", "cr:state 0", "cr:ok contacts"].join("\n")

    function test_parse() {
        const b = Contacts.parse(answer);
        compare(b.serial, "56853bd8");
        compare(b.ok, "contacts");
        compare(b.state, 0);
        // Şükrü's number in two accounts is one row, starred from the second;
        // a contact without a number is left out
        compare(b.contacts.length, 4);
        compare(b.contacts.map(c => c.name).join("|"), "Ada|Ali Yılmaz|Ender, Office|Şükrü Işık");
        const s = b.contacts[3];
        verify(s.starred);
        compare(s.kind, "mobile");
        compare(s.key, "5551112233");
        compare(b.contacts[1].kind, "other");
        // a name with a comma in it
        compare(b.contacts[2].number, "02125550000");
        // newest first
        compare(b.calls.length, 4);
        compare(b.calls[0].type, 3);
        compare(b.calls[1].name, "");
    }

    function test_errors() {
        const b = Contacts.parse("cr:via adb\ncr:error ssh cannot reach the phone, and adb has no phone 56853bd8\n");
        compare(b.via, "adb");
        compare(b.ok, "");
        compare(b.error, "ssh cannot reach the phone, and adb has no phone 56853bd8");
    }

    function test_dialable_and_keys() {
        compare(Contacts.dialable("+90 (555) 111-22-33"), "+905551112233");
        compare(Contacts.dialable("*123#"), "*123#");
        compare(Contacts.dialable("12+34"), "1234");
        compare(Contacts.dialable("'; rm -rf /"), "");
        compare(Contacts.numberKey("+90 555 111 22 33"), Contacts.numberKey("0555 111 22 33"));
        compare(Contacts.fold("Şükrü IŞIK"), "sukru isik");
    }

    function test_nothing_typed() {
        const rows = Contacts.rows(Contacts.parse(answer), "", {
            "nowMs": now,
            "recent": 8
        });
        // the newest calls, one row per number, named from the contacts;
        // then the starred, then everybody else by name
        compare(rows.map(r => r.name).join("|"), "Ali Yılmaz|Şükrü Işık|+905559990000|Ada|Ender, Office");
        compare(rows[0].icon, "call_missed");
        compare(rows[0].comment, "missed 2 h ago  ·  other  ·  +905552223344");
        compare(rows[1].icon, "call_made");
        compare(rows[2].who, "+905559990000");
    }

    function test_typing_a_name() {
        const b = Contacts.parse(answer);
        // without the accents, and Turkish's dotless ı as i
        compare(Contacts.rows(b, "sukru", {
            "nowMs": now
        })[0].name, "Şükrü Işık");
        compare(Contacts.rows(b, "isik", {
            "nowMs": now
        })[0].name, "Şükrü Işık");
        // each word starts one of the name's words
        compare(Contacts.rows(b, "ali y", {
            "nowMs": now
        })[0].name, "Ali Yılmaz");
        // names that start with it, the one called last first, before one
        // that only holds it
        const a = Contacts.rows(b, "a", {
            "nowMs": now
        });
        compare(a.map(r => r.name).join("|"), "Ali Yılmaz|Ada");
        compare(a[1].comment, "mobile  ·  +905553334455");
        compare(Contacts.rows(b, "fic", {
            "nowMs": now
        })[0].name, "Ender, Office");
        compare(Contacts.rows(b, "zz", {
            "nowMs": now
        }).length, 0);
        // the row for Şükrü says when he was called last
        compare(Contacts.rows(b, "şükrü", {
            "nowMs": now
        })[0].comment, "mobile  ·  +905551112233  ·  outgoing 5 h ago");
    }

    function test_typing_a_number() {
        const b = Contacts.parse(answer);
        // the number as typed first, then whoever has it
        const rows = Contacts.rows(b, "0555 222 33 44", {
            "nowMs": now
        });
        compare(rows[0].name, "Call 05552223344");
        compare(rows[0].number, "05552223344");
        compare(rows[0].who, "Ali Yılmaz");
        compare(rows[0].comment, "Ali Yılmaz  ·  other");
        compare(rows[1].name, "Ali Yılmaz");
        // part of a number; a caller who is not in the contacts
        const part = Contacts.rows(b, "999", {
            "nowMs": now
        });
        compare(part[0].name, "Call 999");
        compare(part[1].name, "+905559990000");
        compare(part[1].icon, "call_received");
        // too short to be a number: no row of its own
        verify(!Contacts.looksLikeNumber("12"));
    }

    function test_ago() {
        compare(Contacts.agoText(now - 30000, now), "now");
        compare(Contacts.agoText(now - 5 * 60000, now), "5 min ago");
        compare(Contacts.agoText(now - 3 * 86400000, now), "3 d ago");
    }
}
