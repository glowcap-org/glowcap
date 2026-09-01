// Consistent restore of one Rooms checkpoint and its external-effect ledger.

import { openCheckpoint, type RoomsSessionDiskState } from "./checkpoint.ts";
import type { RoomsSessionDocumentStore } from "./documents.ts";
import { type EffectsState, openEffects } from "./effects.ts";

export async function openSessionStorage(
	documents: RoomsSessionDocumentStore,
): Promise<{ disk: RoomsSessionDiskState; effects: EffectsState }> {
	const checkpoint = await openCheckpoint(documents);
	const disk = checkpoint.disk;
	const effects = await openEffects(documents, checkpoint.created);
	const checkpointIds = new Set(disk.recent.map((operation) => operation.id));
	if (effects.recent.some((operation) => operation.revision > disk.revision)) {
		throw new Error("Rooms session effect ledger is ahead of its checkpoint revision");
	}
	if (
		effects.recent.some((operation) => checkpointIds.has(operation.id)) ||
		effects.pending.some((operation) => checkpointIds.has(operation.id))
	) {
		throw new Error("Rooms session operation id appears in more than one durable ledger");
	}
	return { disk, effects };
}
