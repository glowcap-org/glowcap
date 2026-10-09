// The panel at the top of every conversation, and the line that says what the
// address above a conversation actually reaches.
//
// A person reads this more than anything else in the product, and it was the
// furthest from how anybody talks: "Your live view begins with this arrival",
// "The room did not provide earlier messages", "The directory introduced the
// person who held this name when the conversation opened, then stepped out".
//
// Three questions get answered here and nothing else belongs: how far back the
// messages go, who can get in, and who can read what you type.

/** The directory view, which is a command surface rather than a chat. */
export const conversationDirectory =
	"Rooms you join show up in the list. Commands you type here run on this server and their results stay in this view.";

/** How far back the messages go. */
export type EarlierHistory = "loading" | "shown" | "empty" | "unavailable" | "none";

export function conversationBeginning(earlier: EarlierHistory): string {
	switch (earlier) {
		case "loading":
			return "You're seeing messages from when you joined. Checking for earlier ones. ";
		case "shown":
			return "This conversation includes messages saved before you joined. ";
		case "empty":
			return "Nothing was saved before you joined. ";
		case "unavailable":
			return "The room didn't send earlier messages. ";
		default:
			return "You're seeing messages from when you joined. ";
	}
}

/** Who can get in. The two kinds of room say opposite things, so showing the
 * open sentence over a private room is the worst mistake available here. */
export const conversationPrivateRoom =
	"This room is private. It's not listed and typing the name won't get you in. Everyone here was sent a link, and /invite makes another to pass on.";

export const conversationPublicRoom = "Anyone who knows the name can join. Your name here is just a display name.";

export const conversationJoiningRoom = "Joining this room. Its access policy and messages will appear when you arrive.";

/** A direct conversation.
 *
 * "Not through the server" would be the obvious thing to say and it is not
 * true of both settings: browser to browser skips it, and the relay setting
 * carries the bytes through it encrypted. What holds either way is that the
 * server does not read them, so that is what this says. */
export const conversationLiveDirect =
	"The server never reads these. They go straight to the other person, or encrypted through the server's relay. The conversation follows the person, not the name.";

export const conversationPendingDirect =
	"Not open yet. Your first message asks the server to introduce you. If the name changed hands since, it won't go through.";

export function conversationClosedDirect(nick: string): string {
	return `The connection to ${nick} ended. Saved messages and your draft remain here. Reconnect checks that the name still belongs to the same registration.`;
}

export const directReconnect = "Reconnect";
export const directReconnecting = "Reconnecting…";
export const directPeerUnavailable =
	"The same person is not currently registered here. You can still read saved messages.";
export const directNoRegistration = "This conversation has no directory registration to reconnect to.";
export const directDirectoryUnavailable = "The directory for this conversation is no longer held.";

/** What the address above a conversation reaches, which is not always the
 * conversation. */
export const reachDirect = "Set up through the server above. The conversation has no address of its own.";

export const reachRoomLink = "The room's own link. Anyone with it can get in. Not the server address above.";

export const reachRoomHeld =
	"You're in for as long as this session lasts. The address above is the server's, not the room's. Whoever manages the room can make a permanent link from Capabilities.";

export function reachPublicRoom(room: string): string {
	return `${room} is a name on this server, so the address above is the server's. Anyone who can reach the server can join by that name.`;
}

/** The spinner over earlier messages, which is a label rather than a
 * sentence but still something a screen reader reads out. */
export const conversationLoadingEarlier = "Loading earlier messages";

/** Time suffixes beside message timestamps. */
export const messageTimeAm = "AM";
export const messageTimePm = "PM";

/** Presence as it is said by a person chip. */
export const presenceAway = "away";
export const presenceOnline = "online";
export const presenceOffline = "offline";
export const memberYouSuffix = " (you)";
export function presenceTitle(state: string, reason?: string): string {
	return reason === undefined || reason === "" ? state : `${presenceAway}: ${reason}`;
}

/** The facts on a conversation card. */
export const factPrivateRoom = "Private room";
export const factPublicRoom = "Public room";
export const factDirectMessage = "Direct message";
export const factDirectory = "Directory";
export const factLineOpen = "Open";
export const factLineClosed = "Closed";
export const factLineNotOpen = "Not open yet";
export const factDmRelay = "Through the room relay, encrypted end to end";
export const factDmDirect = "WebRTC, encrypted peer to peer";
export const factDirectoryLocator = "Directory locator";
export function factCopyLocatorFor(directory: string): string {
	return `Copy the locator for ${directory}`;
}
export const factCopyRoomLink = "Copy the room entry link";
export const factThisIs = "This is";
export const factYourName = "Your name";
export const factIrcChannel = "IRC channel";
export function factBridgedVia(origin: string): string {
	return `Bridged via ${origin}`;
}
export const factTopic = "Topic";
export const factTopicNone = "None set";
export const factMembersHere = "Members here";
export const membersTitle = "Members";
export const directoryConnection = "Connection";
export const factLine = "Line";
export const factPath = "Path";
export function factPeopleHere(count: number): string {
	return count === 1 ? "1 person" : `${count} people`;
}
export const factLineLimit = "Line limit";
export function factUpToBytes(bytes: number): string {
	return `Up to ${bytes} bytes`;
}
/** What a message can carry here, shown only when something ordinary is
 * missing: an ordinary room carries everything and says nothing about it.
 * Files are what this membership holds; previews and typing are what the
 * room said it keeps. */
export const factCarries = "Messages here";
export function factCarriesSaid(files: boolean, previews: boolean, typing: boolean): string {
	const without: string[] = [];
	if (!files) without.push("files");
	if (!previews) without.push("link previews");
	if (!typing) without.push("typing indicators");
	const lead = files ? "Text and files" : "Text only";
	if (without.length === 0) return lead;
	const list = without.length === 1 ? without[0] : `${without.slice(0, -1).join(", ")} or ${without.at(-1)}`;
	return `${lead}. No ${list}.`;
}

/** The title bar over a conversation, and what its controls say aloud. */
export const titleNoRoomYet = "No room yet";
export function titleLeaveDirectory(name: string): string {
	return `Leave ${name}`;
}
export function titleAboutDirectory(name: string): string {
	return `About ${name}`;
}
export function titleLeavePrivateRoom(room: string): string {
	return `Leave the private room ${room}. You can only return if somebody hands it to you again`;
}
export function titleLeaveRoom(room: string): string {
	return `Leave #${room}`;
}
export function titleCloseDm(nick: string): string {
	return `Close the direct message with ${nick}`;
}
export const titleDmEncrypted = "Encrypted";
export const titleDmEncryptedLong = "Direct · encrypted, peer-to-peer";
export const railHide = "Hide the rooms list";
export const railShow = "Show the rooms list";
export function titleMembersHere(count: number): string {
	return `Members, ${count} here`;
}
export function titleAboutRoom(room: string): string {
	return `About ${room}`;
}
export function titleAboutDm(nick: string): string {
	return `About the direct message with ${nick}`;
}

/** The rail's rows: what each one says aloud, and what a filtered list
 * says about what it is holding back. */
export const nothingMatches = "Nothing here matches the filter.";
export function heldBack(hidden: number): string {
	return hidden === 1 ? "1 more, hidden by the filter" : `${hidden} more, hidden by the filter`;
}
export function rowDirectoryPhase(phase: string): string {
	return `, directory ${phase}`;
}
export const rowJoining = ", joining";
export const rowNotJoined = ", not joined";
export const rowJoiningStatus = "joining";
export const rowRetryStatus = "retry";
export function rowBridged(badge: string, from: string): string {
	return `, a bridged ${badge} channel via ${from}`;
}
export function rowBridgedFrom(from: string): string {
	return `, a bridged channel via ${from}`;
}
export const rowPrivateRoom = ", a private room";
export function rowOpen(named: string): string {
	return `Open ${named}`;
}
export function rowLeave(named: string, inDir: string, held: boolean): string {
	return `Leave ${named}${inDir}${held ? ". You can only return if somebody hands it to you again" : ""}`;
}
export function rowTakingInvitation(from: string, label: string, onDir: string): string {
	return `Taking up ${from}'s invitation to ${label}${onDir}`;
}
export function rowTakeInvitation(from: string, label: string, onDir: string): string {
	return `Take up ${from}'s invitation to ${label}${onDir}`;
}
export function rowDeclineTitle(label: string): string {
	return `Decline ${label}`;
}
export function rowDeclineInvitation(from: string, label: string, onDir: string): string {
	return `Decline ${from}'s invitation to ${label}${onDir}`;
}
export function rowJoinRoomOn(name: string): string {
	return `Join a room on ${name}`;
}

/** Why the field under a conversation cannot send right now. */
export const cannotSendPaused = "You cannot send while your access is paused.";
export const cannotSendReadOnly = "Your session link is read only, so you can't send here.";
export const cannotJoinReadOnly = "Your session link is read only, so you can't join another room.";
export const cannotSendDmClosed = "This direct conversation is closed.";
export const cannotSendRegistrationEnded =
	"This nickname registration ended. Start a new conversation with its current holder.";
export const cannotSendObserver = "You are here as an observer. An invitation to take part is what lets you post.";
/** An observer seat on a bridged room: the bridge runs one way, so the seat
 * it hands out cannot post. Said in the bridge's terms rather than the
 * observer's, because no invitation would change it. */
export function cannotSendBridgeReadOnly(badge: string): string {
	return `This room is read-only. What's said on ${badge} shows here, and nothing typed here goes back.`;
}
export const cannotSendNotInPrivateRoom = "You are not in this private room. Restore access with a current link.";
export const cannotSendNotInRoom = "You are not in this room.";
export const cannotSendJoining = "Joining this room…";

/** Leaving a conversation from its card. */
export const leaveDmAsk = "Close this conversation";
export const leaveRoomAsk = "Leave this room";
export const leaveDmCommit = "Close";
export const leaveRoomCommit = "Leave";
export function leaveDmSay(nick: string): string {
	return `Close the conversation with ${nick}? The messages on this line go with it. You can start a new one from the room.`;
}
export function leavePrivateRoomSay(room: string): string {
	return `Leave ${room}? You can only return if somebody hands it to you again.`;
}
export function leaveRoomSay(named: string): string {
	return `Leave ${named}? You can come back by its name.`;
}

/** The directory card. */
export function directoryRoomsCount(rooms: number): string {
	return rooms === 1 ? "1 room" : `${rooms} rooms`;
}
export function directoryLinesCount(lines: number): string {
	return lines === 1 ? "1 direct conversation" : `${lines} direct conversations`;
}
export const directoryNothingOpen = "Nothing is open on it.";
export function directoryThisCloses(what: string): string {
	return `This closes ${what}.`;
}
export const directoryAnd = " and ";
export function directoryLeaveLabel(name: string): string {
	return `Leave ${name}`;
}
export function directoryLeaveAsk(name: string): string {
	return `Leave ${name}?`;
}
export const directoryLeaveNameGoesBack = "The name it granted you goes back to it, and somebody else may take it.";
export const directoryLeaveKeep = "Stay";
export const directoryLeaveCommit = "Leave";
export const directoryRetrying = "Retrying…";
export const directoryRetry = "Retry connection";
export const directoryRetryStop = "Stop retrying";
export const directoryLeaveDoor = "Leave this directory…";
export const directoryNoNameYet = "Not yet: no name granted here";
export const directoryReachable = "Others can reach you here";
export const directoryNameNotGranted = "Not granted yet";
export const directoryRoomsYouAreIn = "Rooms you are in";
export const directoryRoomsNone = "None";
export const directoryGrantedNameNote =
	"A directory grants your name for as long as you are connected and takes it back when you are not, so it is not a name you hold anywhere else.";

/** The roster beside a room. */
export function rosterManageIdentity(badge: string): string {
	return `Manage your ${badge} identity`;
}
export function rosterMessageDirectly(name: string): string {
	return `Message ${name} directly`;
}
export const rosterJoinARoom = "Join a room to see who is here.";
export const rosterWaiting = "Waiting for the room roster.";

/** Where you are, on the foot and on a member's row. */
export function standingLabel(about: string, said: string): string {
	return `Where you are${about === "you" ? "" : ` in ${about}`}: ${said}`;
}
export function standingWhyLabel(about: string): string {
	return `Why you stepped away${about === "you" ? "" : `, in ${about}`}`;
}

/** What a room's mark says, and the three answers the access control
 * offers. */
export const markPrivateRoom = "A private room: it is not listed, and only people it was handed to are here";
export const markModeratedRoom =
	"A moderated room: it is listed, and its public name offers watching rather than speaking";
export const accessModeratedSaid = "Anyone with the name can come and watch. An invitation is what lets somebody post.";
export const accessPrivateSaid = "The name gets nobody in. A room link or an invitation still does.";
export const accessOpenSaid = "Anyone with the name can come in and post.";
export const accessTitle = "Room access";
export const accessChange = "Change room access";
export const accessModerated = "Moderated";
export const accessPrivate = "Private";
export const accessOpen = "Open";

/** Delivery state shown on the message it qualifies. */
export const messageEdited = "edited";
export const messageSending = "Sending";
export const messageSendingLong = "Sending…";
export function messageMention(name: string): string {
	return `Mention ${name}`;
}

/** The aside that marks a run of local answers in the log. */
export const onlyYou = "Only you";

/** The log and a message's own controls. */
export const logNewMessages = "New messages";
export const messageMore = "More for this message";
export function messageMoreFrom(from: string): string {
	return `More for this message from ${from}`;
}
export const messageCopyText = "Copy text";
export const messageWithdrawn = "Message withdrawn";
export const messageNotSent = "Not sent";
export const messageNotConfirmed = "Not confirmed";

/** The member card: who this is, what they are called where, and whether a
 * direct message can reach them. */
export const memberHereNow = "Here now";
export function memberAway(standing: string): string {
	return `Away: ${standing}`;
}
export const memberYou = "You";
export const memberAMember = "A member";
export function memberOf(room: string): string {
	return `A member of ${room}`;
}
export const memberYourNames = "Your names";
export const memberNoNameYet = "No directory has granted you one yet";
export const memberGrantedBy = "Granted by";
export const memberNoDirectoryNamed = "No directory has named this reading";
export const memberDirectMessages = "Direct messages";
export const memberYouAre = "You are";
export const memberPresence = "Presence";
export const memberNetwork = "Network";
export const memberOffline = "Offline";
export const memberOnline = "Online";
export const memberAwayLabel = "Away";
export function memberAbout(name: string): string {
	return `About ${name}`;
}
export const memberNoDirectoryNamedYou = "No directory has named you yet";
export function memberCanMessage(name: string): string {
	return `You can message ${name} here`;
}
export const memberNotReachable = "Not reachable on this directory";
