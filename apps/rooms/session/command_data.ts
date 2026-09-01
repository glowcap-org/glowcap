// Bounded JSON command data and aggregate checkpoint validation.

import * as z from "zod/mini";
import { type RoomsSessionState, RoomsSessionStateSchema } from "../lib/rooms_state.ts";

const MAX_COMMAND_JSON = 512 * 1024;

export function validatedRoomsSessionState(candidate: RoomsSessionState): RoomsSessionState {
	const parsed = z.safeParse(RoomsSessionStateSchema, candidate);
	if (!parsed.success) throw new Error("the Rooms session command would produce invalid state");
	return parsed.data;
}

export function commandJson<T>(
	raw: string,
	command: string,
	schema: z.ZodMiniType<T>,
	invalid = `${command} received invalid JSON data`,
): T {
	if (raw.length > MAX_COMMAND_JSON) throw new Error(`${command} JSON is too large`);
	let decoded: unknown;
	try {
		decoded = JSON.parse(raw);
	} catch {
		throw new Error(`${command} takes valid JSON`);
	}
	const parsed = z.safeParse(schema, decoded);
	if (!parsed.success) throw new Error(invalid);
	return parsed.data;
}

export function roomConversation(
	current: RoomsSessionState,
	conversationId: string,
	command: string,
): Extract<RoomsSessionState["conversations"][number], { kind: "room" }> {
	const conversation = current.conversations.find((entry) => entry.id === conversationId);
	if (conversation?.kind !== "room") throw new Error(`${command} names no room in this session`);
	const directory = current.directories.find((entry) => entry.id === conversation.directory);
	if (directory == null || directory.nick === "") {
		throw new Error(`${command} needs a named directory in this session`);
	}
	return conversation;
}
