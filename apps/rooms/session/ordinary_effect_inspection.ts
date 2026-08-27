// Pure retry and revision inspection for one ordinary external effect.

import type { RoomsSessionDiskState } from "./checkpoint.ts";
import type { EffectsState } from "./effects.ts";
import { textDigest, validateOperationId } from "./effects.ts";

export type OrdinaryEffectInspectionResult =
	| { readonly kind: "new"; readonly digest: string }
	| { readonly kind: "committed"; readonly revision: number };

export async function inspectOrdinaryEffect(
	disk: RoomsSessionDiskState,
	effects: EffectsState,
	operationId: string,
	baseRevision: number,
	operationMaterial: string,
): Promise<OrdinaryEffectInspectionResult> {
	validateOperationId(operationId);
	const digest = await textDigest(operationMaterial);
	if (disk.recent.some((operation) => operation.id === operationId)) {
		throw new Error("session operation id is already used by a checkpoint command");
	}
	const committed = effects.recent.find((operation) => operation.id === operationId);
	if (committed != null) {
		if (committed.resultKind != null) {
			throw new Error("session operation id is already used by a result-bearing effect");
		}
		if (committed.digest !== digest) {
			throw new Error("session operation id was reused for a different command");
		}
		if (committed.outcome === "abandoned") {
			throw new Error("session operation was abandoned and cannot be retried");
		}
		return { kind: "committed", revision: committed.revision };
	}
	const pending = effects.pending.find((operation) => operation.id === operationId);
	if (pending != null) {
		if (pending.type === "result") {
			throw new Error("session operation id is already used by a result-bearing effect");
		}
		if (pending.digest !== digest) {
			throw new Error("session operation id was reused for a different command");
		}
		throw new Error("session operation outcome is unresolved and will not be retried automatically");
	}
	if (baseRevision !== disk.revision) {
		throw new Error(`session revision changed from ${baseRevision} to ${disk.revision}`);
	}
	return { kind: "new", digest };
}
