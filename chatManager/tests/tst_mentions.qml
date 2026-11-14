import QtQuick
import QtTest
import "../mentions.js" as Mentions

// Typing "@" to mention somebody: when the picker opens, who it offers, and
// what a message with a picked name in it goes out as.
TestCase {
    name: "Mentions"

    readonly property var members: [
        {
            "id": "@ada:example.org",
            "name": "Ada",
            "mention": "[Ada](https://matrix.to/#/@ada:example.org)"
        },
        {
            "id": "@ada2:example.org",
            "name": "Ada Lovelace",
            "mention": "[Ada Lovelace](https://matrix.to/#/@ada2:example.org)"
        },
        {
            "id": "@bea:example.org",
            "name": "Bea",
            "mention": "[Bea](https://matrix.to/#/@bea:example.org)"
        }
    ]

    function test_at_the_start_of_a_word_opens_the_picker() {
        compare(Mentions.queryAt("@", 1).query, "");
        compare(Mentions.queryAt("hi @ad", 6).start, 3);
        compare(Mentions.queryAt("hi @ad", 6).query, "ad");
        compare(Mentions.queryAt("(@ad", 4).query, "ad");
        // A name has spaces in it.
        compare(Mentions.queryAt("@Ada Lo", 7).query, "Ada Lo");
    }

    function test_an_email_address_is_not_a_mention() {
        compare(Mentions.queryAt("ada@example.org", 15), null);
        compare(Mentions.queryAt("mail me@", 8), null);
    }

    function test_only_up_to_the_cursor_and_the_line() {
        compare(Mentions.queryAt("@ada", 0), null);
        compare(Mentions.queryAt("@ada\nhello", 10), null);
        compare(Mentions.queryAt("@ hello", 7), null, "a space straight after @ is not a name");
        compare(Mentions.queryAt("no at sign", 5), null);
    }

    function test_the_pool_is_members_then_whoever_wrote() {
        const messages = [
            {
                "senderId": "@cem:example.org",
                "senderName": "Cem",
                "fromMe": false,
                "kind": "text"
            },
            {
                "senderId": "@ada:example.org",
                "senderName": "Ada (old name)",
                "fromMe": false,
                "kind": "text"
            },
            {
                "senderId": "@me:example.org",
                "senderName": "Me",
                "fromMe": true,
                "kind": "text"
            },
            {
                "senderId": "@bot:example.org",
                "senderName": "Server",
                "fromMe": false,
                "kind": "system"
            }
        ];
        const people = Mentions.pool(members, messages);
        compare(people.length, 4);
        compare(people[0].name, "Ada", "the provider's name wins over an old message's");
        compare(people[3].id, "@cem:example.org");
        compare(people[3].mention, "", "a sender has no mention markup of their own");
    }

    function test_best_match_first() {
        const found = Mentions.candidates(members, "lov", 6);
        compare(found.length, 1);
        compare(found[0].name, "Ada Lovelace", "a word of the name");

        const ada = Mentions.candidates(members, "ada", 6);
        compare(ada.length, 2);
        compare(ada[0].name, "Ada");

        compare(Mentions.candidates(members, "bea:exa", 6)[0].name, "Bea", "the id counts too");
        compare(Mentions.candidates(members, "", 2).length, 2, "nothing typed offers everyone, up to the limit");
        compare(Mentions.candidates(members, "zed", 6).length, 0);
    }

    function test_picking_inserts_the_name_or_the_id_when_shared() {
        compare(Mentions.insertion(members[0], members), "@Ada");
        const twins = members.concat([
            {
                "id": "@other:example.org",
                "name": "Bea",
                "mention": "x"
            }
        ]);
        compare(Mentions.insertion(twins[2], twins), "@bea:example.org", "two Beas are told apart by id");
        compare(Mentions.insertion({
            "id": "905551234567",
            "name": "Bea"
        }, twins), "@905551234567", "an id without its own @ gets one");
    }

    function test_names_become_mentions_on_the_way_out() {
        compare(Mentions.link("hi @Ada, and @Bea!", members), "hi [Ada](https://matrix.to/#/@ada:example.org), and [Bea](https://matrix.to/#/@bea:example.org)!");
        compare(Mentions.link("@Ada Lovelace was first", members), "[Ada Lovelace](https://matrix.to/#/@ada2:example.org) was first", "the longest name first");
        compare(Mentions.link("ask @bea:example.org", members), "ask [Bea](https://matrix.to/#/@bea:example.org)");
    }

    function test_what_is_not_a_mention_stays_text() {
        compare(Mentions.link("@Adam is not Ada", members), "@Adam is not Ada", "the end of a word, not part of one");
        compare(Mentions.link("mail ada@Ada.org", members), "mail ada@Ada.org");
        compare(Mentions.link("`@Ada` and\n```\n@Bea\n```", members), "`@Ada` and\n```\n@Bea\n```", "never inside code");
        compare(Mentions.link("@Cem", members), "@Cem", "somebody who is not a member");
        compare(Mentions.link("@Ada", [
            {
                "id": "@ada:example.org",
                "name": "Ada"
            }
        ]), "@Ada", "a provider without mention markup leaves the name as text");
    }
}
