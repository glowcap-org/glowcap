import { ROOM_MENTIONS } from "../../../lib/limits.ts";

/** Whether `who` is a room-wide word rather than a person. */
export function addressesEveryone(who: string): boolean {
	return ROOM_MENTIONS.includes(who.toLowerCase());
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
