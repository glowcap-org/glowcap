// Creation acquires a room without choosing the displayed conversation.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { RoomPolicy } from "../../room_policy.ts";
import type { ConversationOpening } from "./openings.ts";
import { fieldKey } from "./model.ts";

export async function createManagedRoom(
	session: ManagedRoomsSession,
	directory: string,
	name: string,
	policy: RoomPolicy,
	opening?: ConversationOpening,
): Promise<string> {
	const signal = opening?.signal;
	signal?.throwIfAborted();
	const original = (session.current ?? await session.refresh()).intent.directories.find((row) =>
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
	await session.execute(operation, () =>
		session.command("openManagedRoom", args, operation, (snapshot) => {
			signal?.throwIfAborted();
			const current = snapshot.intent.directories.find((row) => row.id === directory);
			if (current == null || current.access !== access || current.source !== source) {
				throw new LocalRefusal("directory-changed");
			}
		}, signal), async (command) => {
		await session.completeResult(command);
	}, opening == null ? undefined : { signal, settled: () => opening.acquired(operation) });
	return operation;
}
