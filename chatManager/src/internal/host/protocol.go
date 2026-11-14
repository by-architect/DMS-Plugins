// Package chat hosts chat provider bridges.
//
// A bridge is an external program that translates one messaging service into
// newline-delimited JSON (see docs/CHAT-PLUGINS.md). This package spawns them,
// keeps them alive, writes everything they report into the shared store, and
// exposes chat.* methods to the shell. Bridges own protocol knowledge and
// credentials; everything else is here so it gets written once.
package host

import "encoding/json"

// ProtocolVersion is the contract version this host speaks. A bridge announces
// its own in the ready event, and one we do not recognise is refused rather
// than parsed on a guess.
const ProtocolVersion = 1

// Methods the host calls on a bridge.
const (
	MethodConfigure = "configure"
	MethodSend      = "send"
	// MethodMarkRead says a conversation has been read: chatId, and upTo, the
	// time it has been read as far as. messages itemises what that made read --
	// each incoming message's id, senderId and ts as the bridge reported them,
	// newest first, a few hundred at most -- because a service that posts read
	// receipts names exact messages, and a bridge only remembers the ones that
	// arrived while it was running. An older host sends no messages, so a
	// bridge still has to make do with upTo alone.
	MethodMarkRead   = "markRead"
	MethodFetchMedia = "fetchMedia"
	MethodHistory    = "history"
	MethodSearch     = "search"
	MethodLogin      = "login"
	MethodAuthSubmit = "authSubmit"
	MethodLogout     = "logout"
	MethodRevoke     = "revoke"
	MethodShutdown   = "shutdown"

	// Answering an invitation to a conversation: joining it, or turning it
	// down. Only services that have a notion of being invited implement these,
	// which is what the invites capability says.
	MethodAcceptInvite  = "acceptInvite"
	MethodDeclineInvite = "declineInvite"

	// MethodReact adds a reaction to a message (chatId, messageId, key) and
	// answers with the reaction's own id; MethodUnreact takes one of ours back
	// (chatId, messageId, reactionId, key). The reactions capability.
	MethodReact   = "react"
	MethodUnreact = "unreact"

	// MethodEdit replaces the text of one of our own messages (chatId,
	// messageId, text). The edit capability.
	MethodEdit = "edit"

	// MethodTyping says whether we are typing into a conversation (chatId,
	// typing). Best effort, never waited on. The typing capability.
	MethodTyping = "typing"

	// MethodStartChat opens a conversation from whatever the user typed to
	// reach it -- a user, a room address -- and answers with its chatId, and a
	// name when the provider has one. The startChat capability.
	MethodStartChat = "startChat"

	// MethodSetMuted carries a mute the user set here to the service, so every
	// other client of theirs is silenced too (chatId, muted). The mute
	// capability.
	MethodSetMuted = "setMuted"

	// MethodMembers lists who is in a conversation (chatId), for the picker
	// that typing "@" opens in the composer. The members capability.
	MethodMembers = "members"
)

// Events a bridge pushes to the host.
const (
	EventReady    = "ready"
	EventState    = "state"
	EventAuth     = "auth"
	EventChat     = "chat"
	EventChats    = "chats"
	EventMessage  = "message"
	EventMessages = "messages"
	EventStatus   = "status"
	EventDeleted  = "deleted"
	EventSync     = "sync"
	EventLog      = "log"
	// EventChatGone is a conversation that has stopped existing at the
	// provider: an invitation answered on another device, most of all. Nothing
	// would ever update such a row again, so it is removed -- unless it holds
	// messages somebody actually wrote, which are never dropped on a
	// provider's say-so.
	EventChatGone = "chatGone"

	// EventReaction is one reaction to a message, and EventReactions a batch of
	// them. A reaction taken back arrives as EventDeleted naming the reaction's
	// own id, the way a deleted message does.
	EventReaction  = "reaction"
	EventReactions = "reactions"

	// EventTyping is who is typing into a conversation right now, by name: the
	// whole list each time, empty when nobody is. Relayed to the shell as it
	// comes and never stored.
	EventTyping = "typing"

	// EventAccount is what the provider wants its own settings page to show
	// about the account: who is signed in, whether the device is trusted. The
	// host relays it untouched and makes nothing of it.
	EventAccount = "account"
)

// Capabilities a bridge may declare. The UI hides affordances a provider has
// not claimed, so an unsupported action is never offered rather than failing
// when it is used.
const (
	CapSend     = "send"
	CapMarkRead = "markRead"
	CapMedia    = "media"
	CapReply    = "reply"
	CapRevoke   = "revoke"
	CapSearch   = "search"
	CapThreads  = "threads"
	CapRichText = "richText"
	CapPresence = "presence"
	CapGroups   = "groups"
	// CapInvites is a provider where a conversation can arrive as an invitation
	// you have not answered: a Matrix room invite, a group you have been added
	// to but not joined. Such a conversation carries the "invite" tag until it
	// is answered.
	CapInvites = "invites"

	// CapHistory is a provider that can fetch older messages when asked. The
	// host then waits for the history call to finish -- the bridge sends the
	// messages as a backfill batch before it answers -- and a conversation
	// opened short of its beginning offers to page further back.
	CapHistory = "history"

	// CapReactions, CapEdit, CapTyping, CapStartChat and CapMute say the
	// matching method above is implemented; reactions, edits and typing are
	// also what the provider reports.
	CapReactions = "reactions"
	CapEdit      = "edit"
	CapTyping    = "typing"
	CapStartChat = "startChat"
	CapMute      = "mute"

	// CapMembers is a provider that answers MethodMembers: who can be
	// mentioned in a conversation, and how a mention of them is written.
	CapMembers = "members"
)

// bridgeCall is what the host writes to a bridge's stdin.
type bridgeCall struct {
	ID     int            `json:"id"`
	Method string         `json:"method"`
	Params map[string]any `json:"params,omitempty"`
}

// bridgeError is the failure detail on a call reply.
type bridgeError struct {
	Code    string `json:"code"`
	Message string `json:"message,omitempty"`
}

func (e *bridgeError) String() string {
	if e == nil {
		return ""
	}
	if e.Message != "" {
		return e.Code + ": " + e.Message
	}
	return e.Code
}

// bridgeFrame is one line of a bridge's stdout. It is either a reply to a call
// (Event empty, ID set) or an unprompted event (Event set).
//
// One struct rather than two because the two share a stream and are told apart
// by which fields are populated -- decoding into a single shape keeps that
// decision in one place.
type bridgeFrame struct {
	// Reply fields.
	ID     int             `json:"id"`
	OK     *bool           `json:"ok"`
	Result json.RawMessage `json:"result"`
	Error  *bridgeError    `json:"error"`

	// Event fields.
	Event        string   `json:"event"`
	Protocol     int      `json:"protocol"`
	Capabilities []string `json:"capabilities"`
	State        string   `json:"state"`

	// Auth.
	Method string `json:"method"`
	QR     string `json:"qr"`
	Code   string `json:"code"`
	URL    string `json:"url"`
	// Fields are for method "form": a provider that signs in with typed
	// credentials rather than a scannable code. The host renders them, sends
	// the values straight back with authSubmit, and never stores them.
	Title  string          `json:"title"`
	Fields []wireAuthField `json:"fields"`

	// Payloads. Singular and batch forms are both accepted; the batch forms
	// exist so a history sync costs one transaction instead of thousands.
	Chat      *wireChat      `json:"chat"`
	Chats     []wireChat     `json:"chats"`
	Message   *wireMessage   `json:"message"`
	Messages  []wireMessage  `json:"messages"`
	Reaction  *wireReaction  `json:"reaction"`
	Reactions []wireReaction `json:"reactions"`

	// Backfill marks a messages batch as older history fetched on request:
	// stored where it belongs, and never counted as unread -- it is older than
	// anything the conversation held, so nobody is waiting on it.
	Backfill bool `json:"backfill"`

	// Users is who is typing, for a typing event.
	Users []string `json:"users"`

	// Account is the provider's account summary, for an account event. Kept
	// raw: it is the provider's own settings page that reads it.
	Account json.RawMessage `json:"account"`

	// Status / deletion.
	ChatID    string `json:"chatId"`
	MessageID string `json:"messageId"`
	Status    string `json:"status"`

	// Sync progress.
	Done  int `json:"done"`
	Total int `json:"total"`

	// Log. Carried as "text" rather than "message" so the key never collides
	// with the message event's object of the same name.
	Level string `json:"level"`
	Text  string `json:"text"`
}

func (f bridgeFrame) isReply() bool { return f.Event == "" && f.ID != 0 }

// wireChat is a chat as a bridge sends it.
//
// Unread is a pointer so "the bridge did not mention unread" is distinguishable
// from "the bridge says zero" -- the former must not clear a badge the host
// derived itself.
type wireChat struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	IsGroup  bool   `json:"isGroup"`
	LastTS   int64  `json:"lastTs"`
	LastText string `json:"lastText"`
	Unread   *int   `json:"unread"`
	// ReadUpTo is how far the provider itself says this conversation has been
	// read -- from a read receipt, a server-side read marker, another client.
	// Zero means it has no opinion, which is not the same as "nothing read".
	ReadUpTo int64 `json:"readUpTo"`
	// Pointers so "the bridge did not mention this" is distinguishable from
	// "the bridge says false" -- otherwise a partial update unarchives a chat.
	Archived     *bool    `json:"archived"`
	Muted        *bool    `json:"muted"`
	AvatarPath   string   `json:"avatarPath"`
	Subject      string   `json:"subject"`
	Participants []string `json:"participants"`
	Folder       string   `json:"folder"`
	// Handles are the other identifiers this conversation answers to -- a phone
	// number, an email address, a username. Only the bridge knows them.
	Handles []string `json:"handles"`
	// Tags say what kind of conversation this is: archived, status, channel,
	// broadcast, business, and whatever else the service distinguishes.
	Tags []string `json:"tags"`
}

// wireMessage is a message as a bridge sends it. Media arrives as a path the
// bridge wrote, a small base64 thumbnail, or a ref to fetch later -- never as
// a full inline payload.
type wireMessage struct {
	ID         string `json:"id"`
	ChatID     string `json:"chatId"`
	TS         int64  `json:"ts"`
	FromMe     bool   `json:"fromMe"`
	SenderID   string `json:"senderId"`
	SenderName string `json:"senderName"`
	// SenderAvatarPath is optional; groups without per-sender pictures simply
	// fall back to an initial.
	SenderAvatarPath string   `json:"senderAvatarPath"`
	Kind             string   `json:"kind"`
	Text             string   `json:"text"`
	BodyHTML         string   `json:"bodyHtml"`
	Status           string   `json:"status"`
	ReplyTo          string   `json:"replyTo"`
	CC               []string `json:"cc"`
	BCC              []string `json:"bcc"`

	LinkURL   string `json:"linkUrl"`
	LinkTitle string `json:"linkTitle"`
	LinkDesc  string `json:"linkDesc"`
	LinkImage string `json:"linkImage"`

	MediaPath  string `json:"mediaPath"`
	MediaBytes string `json:"mediaBytes"`
	MediaRef   string `json:"mediaRef"`
	MediaMime  string `json:"mediaMime"`
	MediaW     int    `json:"mediaW"`
	MediaH     int    `json:"mediaH"`
	FileName   string `json:"fileName"`
	FileSize   int64  `json:"fileSize"`
	Duration   int    `json:"duration"`

	// EditedTS is when the text was last edited, zero when it never was. It is
	// what lets the store tell a newer version of a message from an older one
	// arriving late -- see the edit rules in store.go.
	EditedTS int64 `json:"editedTs"`

	// Silent is the service's own notification settings saying this message
	// should not interrupt anyone: a room set to mentions only, or muted on
	// another device. Highlight is the opposite: it names us, and gets
	// through even where group notifications are off.
	Silent    bool `json:"silent"`
	Highlight bool `json:"highlight"`
}

// wireReaction is one reaction as a bridge sends it: its own id, the message it
// is on, and the key -- an emoji, usually, but any short text a service allows.
type wireReaction struct {
	ID         string `json:"id"`
	ChatID     string `json:"chatId"`
	MessageID  string `json:"messageId"`
	Key        string `json:"key"`
	SenderID   string `json:"senderId"`
	SenderName string `json:"senderName"`
	FromMe     bool   `json:"fromMe"`
	TS         int64  `json:"ts"`
}

// sendResult is what a bridge returns from a successful send.
type sendResult struct {
	MessageID string `json:"messageId"`
}

// historyReply is what a bridge with the history capability answers a history
// call with, once the messages it found have been sent. HasMore false is the
// beginning of the conversation reached; absent is a bridge that cannot tell.
type historyReply struct {
	HasMore *bool `json:"hasMore"`
}

// reactReply is what a bridge returns from a react call.
type reactReply struct {
	ReactionID string `json:"reactionId"`
}

// startChatReply is what a bridge returns from a startChat call.
type startChatReply struct {
	ChatID string `json:"chatId"`
	Name   string `json:"name"`
}

// Member is one person in a conversation, as a bridge answers MethodMembers.
//
// Mention is how a mention of them is written into a message, in the
// provider's own markup -- for Matrix a Markdown link to their matrix.to
// address, which the bridge sends as a pill that notifies them. Empty is a
// provider whose mentions are only ever the name, as text.
type Member struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Mention    string `json:"mention,omitempty"`
	AvatarPath string `json:"avatarPath,omitempty"`
}

// membersReply is what a bridge returns from a members call.
type membersReply struct {
	Members []Member `json:"members"`
}

// fetchMediaResult is what a bridge returns from a successful fetchMedia.
type fetchMediaResult struct {
	Path  string `json:"path"`
	Bytes string `json:"bytes"`
	Mime  string `json:"mime"`
}

// wireAuthField is one input in a form-based sign-in.
//
// Type is advisory and drives how the host renders the input: "password" is
// masked, "url" and "text" are not. Anything unrecognised is treated as text,
// so a bridge asking for something new degrades to a plain box rather than
// showing nothing.
type wireAuthField struct {
	Key         string `json:"key"`
	Label       string `json:"label"`
	Type        string `json:"type"`
	Value       string `json:"value"`
	Placeholder string `json:"placeholder"`
	Required    bool   `json:"required"`
}
