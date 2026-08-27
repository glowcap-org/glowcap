// Consistent restore of one Rooms checkpoint and its external-effect ledger.

import { openCheckpoint, type RoomsSessionDiskState } from "./checkpoint.ts";
import { type EffectsState, openEffects } from "./effects.ts";

export async function openSessionStorage(
	directory: string,
): Promise<{ disk: RoomsSessionDiskState; effects: EffectsState }> {
	await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
	const checkpoint = await openCheckpoint(directory);
	const disk = checkpoint.disk;
	const effects = await openEffects(directory, checkpoint.created);
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
