// What a slash command says back, in the log of the conversation it ran in,
// and why one could not run.

/** Why a command could not enter a room on this tab, when the missing handle
 * is a directory. */
export const notOnADirectory = "This browser isn't on a directory.";
/** Why `/quit` could not give a directory back. */
export const noDirectoryToGiveBack = "There is no directory to give back.";
/** Why a direct line cannot open to this reader. */
export const directNotSelf = "You can't start a direct message with yourself.";
/** Why a room entry link was not a room entry link. */
export const notARoomEntryLink = "That link didn't open a room: that isn't a room entry link";
/** Why a room entry link did not open, once the adapter knows the cause. */
export function thatLinkDidNotOpen(why: string): string {
	return `That link didn't open a room: ${why}`;
}
/** Why `/invite` found nothing to hand over: the conversation is not a room
 * this session holds a row for. */
export const noRoomToHandOver = "There is no room here to hand over.";
/** Why `/invite` could not hand this room over: the member holds a seat in
 * it, not the room itself. A listed room says the way in instead. */
export function inviteWithoutTheRoom(room: string, listed: boolean): string {
	return listed
		? `You don't hold this room to hand over. Anyone can join it by name: tell them #${room}.`
		: "You don't hold this room to hand over. Ask whoever let you in to hand it on.";
}
/** Why `/away` found no room: the words have nobody to reach. */
export const noRoomToSayThatIn = "There is no room to say that in.";
/** Why `/edit` and `/delete` found no line: this window holds the handle to
 * none of the reader's lines here. */
export const noLineToChange = "There is no message of yours here that can still be changed.";
export const noLineToTakeBack = "There is no message of yours here that can still be taken back.";
/** Why `/subject` could not set one: the room handed this membership no
 * subject capability. */
export const noSubjectOffered = "This room did not offer a subject to set.";
/** Why `/kick` and `/moderator` found no room to act on. */
export const noRoomToModerate = "There is no connected room here to moderate.";
/** Why `/kick` could not ask: the room's steward capability is not held here. */
export const kickWithoutModerator =
	"This session holds no moderator capability for this room, so it can't ask anyone to leave.";
/** Why `/link` found no room. */
export const noRoomToLink = "There is no room here to link to.";
/** Why `/link` could not answer for a room this session is not in. */
export function linkRoomNotJoined(room: string): string {
	return `This session isn't in #${room}. Join it first: /join ${room}.`;
}
/** The room link, said back where `/link` was typed. */
export function roomLinkLine(room: string, link: string): string {
	return `Room link for #${room}, anyone holding it can enter: ${link}`;
}
/** The moderator link this session holds, said back where `/moderator` was typed. */
export function moderatorLinkLine(room: string, link: string): string {
	return `Moderator link for #${room}, anyone holding it can ask members to leave: ${link}`;
}
/** Why a direct line cannot open to `who`. */
export function notRegisteredForDirect(who: string): string {
	return `${who} isn't registered for direct messages here.`;
}

/** /ignore and /unignore. */
export const ignoringNobody = "You aren't ignoring anybody.";
export function ignoringThese(names: string): string {
	return `You're ignoring ${names}.`;
}
export function ignoringNow(name: string): string {
	return `Ignoring ${name} in this window. Their messages still reach the room.`;
}
export const ignoringYourOwnName = " That is also your own name here, so your own messages stay shown.";
export function noLongerIgnoring(name: string): string {
	return `No longer ignoring ${name}.`;
}
export function wereNotIgnoring(name: string): string {
	return `You weren't ignoring ${name}.`;
}

/** /list and /directories. */
export const thisDirectory = "This directory";
export const noDirectoryHeld = "This tab holds no directory.";
export function advertisingNoRooms(whose: string): string {
	return `${whose} is advertising no rooms.`;
}
export function noDirectoryCalled(asked: string, held: string): string {
	return `No directory here is called "${asked}". This tab holds ${held}.`;
}
export function directoryNamesMoreThanOne(asked: string, names: string): string {
	return `"${asked}" names more than one: ${names}.`;
}

/** /whois and /subject. */
export function nobodyCalled(name: string): string {
	return `Nobody here is called ${name}.`;
}
export function whoisAway(away: string): string {
	return `away: ${away}`;
}
export const whoisHereNow = "here now";
export const whoisNotHere = "not here just now";
export const noSubject = "This room has no subject.";
export function subjectIs(description: string, link?: string): string {
	return link === undefined ? `The subject is: ${description}` : `The subject is: ${description} (${link})`;
}
