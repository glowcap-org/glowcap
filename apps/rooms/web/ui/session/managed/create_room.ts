// Creation acquires a room without choosing the displayed conversation.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import type { Door } from "./session.ts";
import type { RoomPolicy } from "../../room_policy.ts";
import type { ConversationOpening } from "./openings.ts";
import { fieldKey } from "./model.ts";

export async function createManagedRoom(
	session: Door,
	directory: string,
	name: string,
	policy: RoomPolicy,
	opening?: ConversationOpening,
): Promise<string> {
	const signal = opening?.signal;
	signal?.throwIfAborted();
	const original = (session.current ?? await session.readBeforeSending()).intent.directories.find((row) =>
		row.id === directory
	);
	if (original == null) throw new LocalRefusal("directory-gone");
	const access = original.access;
	const source = original.source;
	const operation = crypto.randomUUID();
	const args = [
		directory,
		name,
		policy.visibility,
		policy.entry,
		policy.speaking,
		`~${fieldKey()}`,
	];
	await session.press(
		operation,
		({ command }) =>
			command("openManagedRoom", args, operation, (snapshot) => {
				signal?.throwIfAborted();
				const current = snapshot.intent.directories.find((row) => row.id === directory);
				if (current == null || current.access !== access || current.source !== source) {
					throw new LocalRefusal("directory-changed");
				}
			}, signal),
		async (command, after) => {
			await after.complete(command);
			// The opening owns the room's departure if it is dismissed. This runs
			// again over the next link when a loss ends it, and finds itself done.
			await opening?.acquired(operation);
		},
		opening == null ? undefined : signal,
	);
	return operation;
}
