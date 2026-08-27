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
