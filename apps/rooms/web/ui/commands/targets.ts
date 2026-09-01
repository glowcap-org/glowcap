// Who a command is talking to, and the sentences for a missing handle.

import { ROOM_MENTIONS } from "../../../lib/limits.ts";

/** Whether `who` is a room-wide word rather than a person. */
export function addressesEveryone(who: string): boolean {
	return ROOM_MENTIONS.includes(who.toLowerCase());
}

/** Why a command could not enter a room on this tab, when the missing handle
 * is a directory. */
export const NOT_ON_A_DIRECTORY = "This browser is not on a directory yet.";

/** Why `/quit` could not give a directory back. */
export const NO_DIRECTORY_TO_GIVE_BACK = "There is no directory to give back.";

/** Why a direct line cannot open to this reader. */
export const DIRECT_NOT_SELF = "You can't start a direct message with yourself.";

/** Why a room entry link was not a room entry link. */
export const NOT_A_ROOM_ENTRY_LINK = "That link did not open a room: that is not a room entry link";

/** Why a room entry link did not open, once the adapter knows the cause. */
export function thatLinkDidNotOpen(why: string): string {
	return `That link did not open a room: ${why}`;
}

/** Why a direct line cannot open to `who`. */
export function notRegisteredForDirect(who: string): string {
	return `${who} is not registered for direct messages here.`;
}

/** Why this nick cannot be offered the room, or null when they can. */
export function inviteWhy(who: string, you: string): string | null {
	const nick = who.trim().replace(/^@/, "").split(/\s+/)[0] ?? "";
	if (nick === "") return "Name who to offer this room to.";
	if (addressesEveryone(nick)) {
		return `@${nick} is everyone in the room. Hand it to one person.`;
	}
	if (you !== "" && nick.toLowerCase() === you.toLowerCase()) {
		return "You already hold this room.";
	}
	return null;
}
