// Read-only projections over one durable Rooms checkpoint and effect ledger.

import type { RoomsSessionDiskState } from "./checkpoint.ts";
import type { EffectsState } from "./effects.ts";
import type { PendingEffectDetail } from "./state_contract.ts";

export function pendingEffectIds(effects: EffectsState): string[] {
	return effects.pending.map((operation) => operation.id);
}

export function pendingEffectDetails(effects: EffectsState): PendingEffectDetail[] {
	return effects.pending.map((operation) =>
		operation.type === "ordinary"
			? { id: operation.id, kind: "external", phase: "unresolved", intent: operation.subject }
			: {
				id: operation.id,
				kind: operation.resultKind,
				phase: operation.marker != null ? "applied" : operation.result != null ? "completed" : "prepared",
				intent: operation.intent,
			}
	);
}

export function pendingResultEffect(
	effects: EffectsState,
	operationId: string,
): PendingEffectDetail & { result: string | null } {
	const pending = effects.pending.find((operation) => operation.id === operationId);
	if (pending?.type !== "result") throw new Error("session has no result-bearing effect with that operation id");
	return {
		id: pending.id,
		kind: pending.resultKind,
		phase: pending.marker != null ? "applied" : pending.result != null ? "completed" : "prepared",
		intent: pending.intent,
		result: pending.result,
	};
}

export function operationKnown(disk: RoomsSessionDiskState, effects: EffectsState, operationId: string): boolean {
	return disk.recent.some((operation) => operation.id === operationId) ||
		effects.recent.some((operation) => operation.id === operationId) ||
		effects.pending.some((operation) => operation.id === operationId);
}
