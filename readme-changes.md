## chats #9

Adds **whatsappChat**, the first chat provider plugin for DMS, and the first plugin in this
repository that ships a compiled program rather than QML.

### What it is

DMS chat plugins do not run in the shell. A chat plugin ships a small program — a **bridge** — that
translates one messaging service into newline-delimited JSON on stdin and stdout. The DMS backend
owns the message store, unread counts, pagination, the attachment cache, notifications and search,
so the bridge only has to speak WhatsApp and report what happened.

This one links WhatsApp as a device, the same way WhatsApp Web does, using
[whatsmeow](https://github.com/tulir/whatsmeow).

### What works

Text, replies, photos, video, voice notes, documents, stickers, location and contact cards, in both
direct and group conversations. Read receipts map onto the sent → delivered → read ladder. Deleting
for everyone works in both directions. History backfill on first link is optional.

Newsletters and broadcast lists are filtered out — they are feeds, and in a busy account they bury
real conversations.

### Two decisions worth knowing about

**Media is not downloaded during history sync.** A year of photos is gigabytes nobody asked for, so
WhatsApp's own embedded thumbnail is shown immediately and the full file is only fetched when the
user opens it. The bridge remembers the last 4000 attachments it has seen in order to do that;
older ones report that they need the conversation reopened.

**The session database is kept out of everything else.** It lives at
`~/.local/share/dms-whatsapp/session.db`, mode 0600 in a 0700 directory, and never touches plugin
settings — that file is the linked device itself, and anyone who can read it can read the account.

### Building

The bridge is Go and must be compiled for the machine it runs on, so it is not shipped prebuilt.
Run `./build.sh` after installing. The plugin refuses to enable until the binary exists and says
so, rather than sitting silently at "disconnected".

`bin/` is gitignored: the compiled bridge is about 25 MB.

### Verified

Built, vetted, and run end to end against the DMS backend in an isolated sandbox: discovered as a
provider, spawned by the host, connected to WhatsApp's servers, and produced a live pairing QR
rendered through the host's QR handler. Not yet linked to a real account.
