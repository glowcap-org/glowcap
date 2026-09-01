// Message mutations against the live conversation graph of one durable session.

import type { PostedLine } from "../lib/room/client.ts";
import { MAX_SCROLLBACK } from "../lib/limits.ts";
import type { DirectRealizationCallbacks } from "./directory_directs.ts";
import type { LiveDirectory } from "./live.ts";

export async function sayInConversation(
	directories: ReadonlyMap<string, LiveDirectory>,
	emitDirect: DirectRealizationCallbacks["emit"],
	kind: "room" | "direct",
	conversationId: string,
	text: string,
): Promise<void> {
	for (const held of directories.values()) {
		const live = kind === "room" ? held.roomRealization.rooms.get(conversationId) : null;
		if (live != null) {
			if (live.pendingLines.length >= MAX_SCROLLBACK) {
				throw new Error("that room has too many line capabilities waiting for their echoes");
			}
			const authority = live.room.say(text);
			live.pendingLines.push(authority);
			try {
				await authority;
			} catch (error) {
				const at = live.pendingLines.indexOf(authority);
				if (at >= 0) live.pendingLines.splice(at, 1);
				throw error;
			}
			return;
		}
		const direct = kind === "direct" ? held.directs.get(conversationId) : null;
		if (direct != null && direct.line.live) {
			const sent = await direct.say(held.nick, text);
			emitDirect(held, conversationId, direct.generation, sent.message, sent.editable, []);
			return;
		}
	}
	throw new Error(
		kind === "room"
			? "that room is not connected in this Rooms session"
			: "that direct conversation is not connected in this Rooms session",
	);
}

export function requireConversationRealization(
	directories: ReadonlyMap<string, LiveDirectory>,
	kind: "room" | "direct",
	conversationId: string,
): void {
	for (const held of directories.values()) {
		if (kind === "room" && held.roomRealization.rooms.has(conversationId)) return;
		const direct = kind === "direct" ? held.directs.get(conversationId) : null;
		if (direct != null && direct.line.live) return;
	}
	throw new Error(
		kind === "room"
			? "that room is not connected in this Rooms session"
			: "that direct conversation is not connected in this Rooms session",
	);
}

export async function editConversationLine(
	directories: ReadonlyMap<string, LiveDirectory>,
	emitDirect: DirectRealizationCallbacks["emit"],
	conversationId: string,
	lineId: number,
	text: string,
): Promise<void> {
	for (const held of directories.values()) {
		const direct = held.directs.get(conversationId);
		if (direct == null) continue;
		emitDirect(held, conversationId, direct.generation, await direct.edit(held.nick, lineId, text), true, []);
		return;
	}
	await postedLine(directories, conversationId, lineId).edit(text);
}

export async function withdrawConversationLine(
	directories: ReadonlyMap<string, LiveDirectory>,
	emitDirect: DirectRealizationCallbacks["emit"],
	conversationId: string,
	lineId: number,
): Promise<void> {
	for (const held of directories.values()) {
		const direct = held.directs.get(conversationId);
		if (direct == null) continue;
		emitDirect(held, conversationId, direct.generation, await direct.withdraw(held.nick, lineId), false, []);
		return;
	}
	const line = postedLine(directories, conversationId, lineId);
	await line.withdraw();
	for (const held of directories.values()) {
		const live = held.roomRealization.rooms.get(conversationId);
		if (live?.postedLines.get(lineId) !== line) continue;
		live.postedLines.delete(lineId);
		line.release();
		return;
	}
}

function postedLine(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	lineId: number,
): PostedLine {
	for (const held of directories.values()) {
		const line = held.roomRealization.rooms.get(conversationId)?.postedLines.get(lineId);
		if (line != null) return line;
	}
	throw new Error("this Rooms session does not hold authority over that line");
}
