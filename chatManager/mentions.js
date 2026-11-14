.pragma library

// Mentioning somebody: typing "@" in the composer, picking who, and the
// message going out with a mention the service knows is one.
//
// Who can be picked comes from two places. A provider with the members
// capability lists the conversation's members, each with the markup a mention
// of them is written in -- for Matrix a link to their matrix.to address, which
// the bridge sends as a pill that notifies them. And whoever has written in
// what is loaded can be picked anywhere, as their name in text, which is all
// some services have.
//
// The field shows "@Ada", which is what was meant and what can be read and
// corrected. Only on the way out does a name picked from the members become
// the mention itself (link), so a draft never fills up with addresses.

// queryAt is the mention being typed at the cursor: where its "@" is, and what
// has been typed after it -- or null when the cursor is not in one.
//
// "@" has to start a word, so an email address never opens the picker, and a
// name may have spaces in it: "@Ada Lo" is still looking for Ada Lovelace. It
// ends at a line break, at another "@", or once it is longer than any name.
function queryAt(text, cursor) {
    const before = String(text || "").slice(0, Math.max(0, cursor));
    const at = before.lastIndexOf("@");
    if (at < 0)
        return null;
    if (at > 0 && !/[\s(\[{"'«“]/.test(before.charAt(at - 1)))
        return null;
    const query = before.slice(at + 1);
    if (query.length > 48 || /[\n@]/.test(query) || /^\s/.test(query))
        return null;
    return {
        "start": at,
        "query": query
    };
}

// pool is everyone who can be mentioned: the members the provider listed,
// then whoever has written in the messages given who is not among them.
// Ourselves never, and nobody without an id to be told apart by.
function pool(members, messages) {
    const out = [];
    const seen = {};
    const list = members || [];
    for (let i = 0; i < list.length; i++) {
        const m = list[i];
        if (!m || !m.id || seen[m.id])
            continue;
        seen[m.id] = true;
        out.push({
            "id": m.id,
            "name": m.name || m.id,
            "mention": m.mention || "",
            "avatarPath": m.avatarPath || ""
        });
    }
    const msgs = messages || [];
    // Newest first, so somebody who has just written is the first of the
    // senders, and their newest picture is the one kept.
    for (let i = msgs.length - 1; i >= 0; i--) {
        const msg = msgs[i];
        if (!msg || msg.fromMe || !msg.senderId || seen[msg.senderId])
            continue;
        if (msg.kind === "system" || msg.kind === "unsupported")
            continue;
        seen[msg.senderId] = true;
        out.push({
            "id": msg.senderId,
            "name": msg.senderName || msg.senderId,
            "mention": "",
            "avatarPath": msg.senderAvatarPath || ""
        });
    }
    return out;
}

// _rank is how well a person matches what was typed, lower being better, or
// -1 for not at all: the name starting with it, then a word of the name, then
// the id, then anywhere in either.
function _rank(person, query) {
    if (query === "")
        return 0;
    const name = person.name.toLowerCase();
    const id = person.id.toLowerCase();
    if (name.startsWith(query))
        return 0;
    if (name.split(/\s+/).some(word => word.startsWith(query)))
        return 1;
    if (id.startsWith(query) || id.startsWith("@" + query))
        return 2;
    if (name.indexOf(query) !== -1 || id.indexOf(query) !== -1)
        return 3;
    return -1;
}

// candidates is who the picker offers for what was typed, best match first,
// at most limit of them.
function candidates(people, query, limit) {
    const q = String(query || "").toLowerCase();
    const scored = [];
    const list = people || [];
    for (let i = 0; i < list.length; i++) {
        const rank = _rank(list[i], q);
        if (rank >= 0)
            scored.push({
                "rank": rank,
                "order": i,
                "person": list[i]
            });
    }
    // The members' own order -- by name -- breaks the ties, then the senders'
    // -- most recent first.
    scored.sort((a, b) => a.rank - b.rank || a.order - b.order);
    return scored.slice(0, limit || 6).map(s => s.person);
}

// _shared is whether a name belongs to more than one of the people.
function _shared(people, name) {
    let count = 0;
    for (let i = 0; i < people.length; i++) {
        if (people[i].name === name && ++count > 1)
            return true;
    }
    return false;
}

// _idToken is how a person's id is written as a mention: as it is when it
// already starts with "@", as a Matrix id does, and after one otherwise.
function _idToken(person) {
    return person.id.startsWith("@") ? person.id : "@" + person.id;
}

// insertion is what picking a person puts in the field: "@" and their name,
// or their id when somebody else in the conversation has the same name -- two
// Adas cannot be told apart by name, so the mention would be a guess.
function insertion(person, people) {
    if (_shared(people || [], person.name))
        return _idToken(person);
    return "@" + person.name;
}

function _isWordChar(c) {
    return c !== "" && (/[0-9_]/.test(c) || c.toLowerCase() !== c.toUpperCase());
}

// link turns the mentions in text into the markup each person's provider
// writes one in, ready to send.
//
// "@Name" for anyone whose name is theirs alone, and "@id" for anyone; the
// longest first, so "@Ada Lovelace" is not taken for "@Ada" with "Lovelace"
// after it. Only at the start of a word and up to the end of one, and never
// inside code: `@Ada` in backticks is about the name, not to her. People with
// no markup of their own -- senders on a service without members -- are left
// as the text they are.
function link(text, members) {
    const source = String(text || "");
    const people = (members || []).filter(m => m && m.id && m.mention);
    if (people.length === 0 || source.indexOf("@") === -1)
        return source;

    const tokens = [];
    for (let i = 0; i < people.length; i++) {
        const person = people[i];
        const name = person.name || "";
        if (name !== "" && !_shared(people, name))
            tokens.push({
                "text": "@" + name,
                "mention": person.mention
            });
        tokens.push({
            "text": _idToken(person),
            "mention": person.mention
        });
    }
    tokens.sort((a, b) => b.text.length - a.text.length);

    // Code fences and inline code are kept apart and put back as they were.
    const parts = source.split(/(```[\s\S]*?```|`[^`\n]*`)/);
    for (let p = 0; p < parts.length; p += 2)
        parts[p] = _linkPlain(parts[p], tokens);
    return parts.join("");
}

function _linkPlain(text, tokens) {
    let out = "";
    let i = 0;
    while (i < text.length) {
        const at = text.indexOf("@", i);
        if (at < 0) {
            out += text.slice(i);
            break;
        }
        out += text.slice(i, at);
        i = at;
        const startsWord = at === 0 || !_isWordChar(text.charAt(at - 1));
        let matched = null;
        if (startsWord) {
            for (let t = 0; t < tokens.length; t++) {
                const token = tokens[t];
                if (text.startsWith(token.text, at) && !_isWordChar(text.charAt(at + token.text.length))) {
                    matched = token;
                    break;
                }
            }
        }
        if (matched) {
            out += matched.mention;
            i = at + matched.text.length;
        } else {
            out += "@";
            i = at + 1;
        }
    }
    return out;
}
