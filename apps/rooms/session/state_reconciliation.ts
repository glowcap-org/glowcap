// Durable commit transaction for facts learned from live Rooms authorities.

import * as z from "zod/mini";
import { type RoomsSessionState, RoomsSessionStateSchema } from "../lib/rooms_state.ts";
import type { RoomsCheckpointImpact } from "./commands.ts";
import { freezeCheckpoint, type RoomsSessionDiskState as DiskState, writeCheckpoint } from "./checkpoint.ts";
import type { RoomsSessionDocumentStore } from "./documents.ts";

export interface RoomsSessionReconciliation {
	impact: RoomsCheckpointImpact;
	change(checkpoint: RoomsSessionState): RoomsSessionState | null;
}

/** Prepare and persist one conditional reconciliation without mutating the
 * caller's in-memory owner. Null means the fact was already applied or was
 * superseded before it reached the serialized commit point. */
export async function reconcileSessionState(
	documents: RoomsSessionDocumentStore,
	disk: DiskState,
	reconciliation: RoomsSessionReconciliation,
): Promise<DiskState | null> {
	const candidate = reconciliation.change(disk.checkpoint);
	if (candidate == null) return null;
	const parsed = z.safeParse(RoomsSessionStateSchema, candidate);
	if (!parsed.success) throw new Error("session reconciliation would produce an invalid checkpoint");
	const checkpoint = freezeCheckpoint(parsed.data);
	if (JSON.stringify(checkpoint) === JSON.stringify(disk.checkpoint)) return null;
	const next: DiskState = {
		...disk,
		workspaceAdoption: "closed",
		checkpoint,
	};
	await writeCheckpoint(documents, next);
	return next;
}
