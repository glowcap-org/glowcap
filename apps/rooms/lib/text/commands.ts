// What a slash command says back, in the log of the conversation it ran in,
// and why one could not run.

/** Why a command could not enter a room on this tab, when the missing handle
 * is a directory. */
export const notOnADirectory = "This browser is not on a directory yet.";
/** Why `/quit` could not give a directory back. */
export const noDirectoryToGiveBack = "There is no directory to give back.";
/** Why a direct line cannot open to this reader. */
export const directNotSelf = "You can't start a direct message with yourself.";
/** Why a room entry link was not a room entry link. */
export const notARoomEntryLink = "That link did not open a room: that is not a room entry link";
/** Why a room entry link did not open, once the adapter knows the cause. */
export function thatLinkDidNotOpen(why: string): string {
	return `That link did not open a room: ${why}`;
}
/** Why a direct line cannot open to `who`. */
export function notRegisteredForDirect(who: string): string {
	return `${who} is not registered for direct messages here.`;
}

/** /ignore and /unignore. */
export const ignoringNobody = "You are not ignoring anybody.";
export function ignoringThese(names: string): string {
	return `You are ignoring ${names}.`;
}
export function ignoringNow(name: string): string {
	return `Ignoring ${name} in this window. Their lines still reach the room.`;
}
export const ignoringYourOwnName = " That is also your own name here, so your own messages stay shown.";
export function noLongerIgnoring(name: string): string {
	return `No longer ignoring ${name}.`;
}
export function wereNotIgnoring(name: string): string {
	return `You were not ignoring ${name}.`;
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

/** /whois and /topic. */
export function nobodyCalled(name: string): string {
	return `Nobody here is called ${name}.`;
}
export function whoisAway(away: string): string {
	return `away: ${away}`;
}
export const whoisHereNow = "here now";
export const whoisNotHere = "not here just now";
export const noTopic = "This room has no topic.";
export function topicIs(topic: string): string {
	return `The topic is: ${topic}`;
}
