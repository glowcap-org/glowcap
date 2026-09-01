// Pure IRC spellings for the native Rooms front. Keeping channel validation,
// member prefixes, projected nicks, and bounded explanatory text together
// prevents the socket/authority owner from becoming a second grammar module.

import { MAX_ROOM } from "../../lib/limits.ts";
import { encodeIrcMessage } from "../protocol.ts";

export function roomName(channel: string): string {
	if (!channel.startsWith("#") || channel.length < 2 || /[\0\r\n ,:]/.test(channel)) {
		throw new Error("a Rooms IRC channel must be # followed by one name");
	}
	const name = channel.slice(1);
	if (name.length > MAX_ROOM) throw new Error(`a room name may be at most ${MAX_ROOM} characters`);
	return name;
}

export function channelForRoom(name: string): string | null {
	const channel = `#${name}`;
	try {
		return roomName(channel) === name ? channel : null;
	} catch {
		return null;
	}
}

export function memberPrefix(nick: string, server: string): string {
	return `${nick}!rooms@${server}`;
}

/** Fit explanatory text to one IRC trailing parameter and mark the omission.
 * Chat content never comes here: the caller refuses it whole. */
export function boundedTrailing(command: string, leading: readonly string[], prefix: string, text: string): string {
	try {
		encodeIrcMessage(command, [...leading, text], prefix);
		return text;
	} catch (error) {
		if (!reason(error).includes("exceeds 512 bytes")) throw error;
	}
	const marker = " … [IRC line limit]";
	let kept = "";
	for (const character of text) {
		try {
			encodeIrcMessage(command, [...leading, kept + character + marker], prefix);
			kept += character;
		} catch {
			break;
		}
	}
	return kept + marker;
}

export function reason(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
