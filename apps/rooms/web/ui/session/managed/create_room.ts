// Creation acquires a room without choosing the displayed conversation.
import type { ManagedRoomsSession } from "./session.ts";
import type { RoomPolicy } from "../../room_policy.ts";
import { WorkspaceConflict } from "./operation.ts";
import { MAX_CONFLICT_REPREPARATIONS } from "./acquisition.ts";
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
	if (original == null) throw new Error("The original directory was removed");
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
	for (let attempt = 0; attempt < MAX_CONFLICT_REPREPARATIONS; attempt++) {
		try {
			await session.execute(operation, () =>
				session.command("openManagedRoom", args, operation, (snapshot) => {
					signal?.throwIfAborted();
					const current = snapshot.intent.directories.find((row) => row.id === directory);
					if (current == null || current.access !== access || current.source !== source) {
						throw new Error("The selected directory authority changed. Review it before creating a room.");
					}
				}, signal), async (command) => {
				await session.completeResult(command);
			}, opening == null ? undefined : { signal, settled: () => opening.acquired(operation) });
			return operation;
		} catch (error) {
			// Conflict proves that no receipt or upstream effect was installed.
			// Every preparation rechecks the same directory/source; uncertain
			// admissions stay at command's existing original receipt owner.
			if (!(error instanceof WorkspaceConflict) || attempt + 1 === MAX_CONFLICT_REPREPARATIONS) {
				throw error;
			}
		}
	}
	throw new Error("Room creation exceeded conflict re-preparation attempts.");
}
