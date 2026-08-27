// Durable identity, checkpoint, revision, and retry admission for one Rooms session.

import * as z from "zod/mini";
import { acceptInitialWorkspace } from "../lib/rooms_session_adoption.ts";
import { type RoomsSessionState, RoomsSessionStateSchema } from "../lib/rooms_state.ts";
import {
	describeOrdinaryEffect,
	effectKind,
	type EffectsState,
	effectText,
	PENDING_OPERATIONS,
	type PendingResultEffect,
	RECENT_OPERATIONS,
	textDigest,
	validateOperationId,
	writeEffects,
} from "./effects.ts";
import {
	decodeHex as unhex,
	ENTROPY_BYTES,
	freezeCheckpoint,
	IDENTITY_BYTES,
	type RoomsSessionDiskState as DiskState,
	writeCheckpoint as write,
} from "./checkpoint.ts";
import type { RoomsCheckpointImpact } from "./commands.ts";
import { RoomsSessionStateObservers } from "./state_observers.ts";
import { inspectOrdinaryEffect } from "./ordinary_effect_inspection.ts";
import { openSessionStorage } from "./state_storage.ts";
import {
	type NewOrdinaryEffectInspection,
	type OrdinaryEffectInspection,
	ordinaryEffectInspection,
	type PendingEffectDetail,
} from "./state_contract.ts";

export type { OrdinaryEffectInspection, PendingEffectDetail } from "./state_contract.ts";

export type RoomsSessionResultApplier = (
	checkpoint: RoomsSessionState,
	kind: string,
	intent: string,
	result: string,
) => RoomsSessionState;
export type RoomsSessionResultValidator = (checkpoint: RoomsSessionState, kind: string, intent: string) => void;

interface RoomsSessionMutation {
	operationId: string;
	baseRevision: number;
	material: string;
	impact: RoomsCheckpointImpact;
	change(checkpoint: RoomsSessionState): RoomsSessionState;
}

export class DurableRoomsSessionState {
	readonly #identitySeed: Uint8Array<ArrayBuffer>;
	readonly #sessionEntropy: Uint8Array<ArrayBuffer>;
	readonly #directory: string;
	#disk: DiskState;
	#effects: EffectsState;
	#tail: Promise<void> = Promise.resolve();
	readonly #inspectionOwner = Symbol("Rooms session state owner");
	readonly #observers = new RoomsSessionStateObservers();

	private constructor(directory: string, disk: DiskState, effects: EffectsState) {
		this.#directory = directory;
		this.#disk = disk;
		this.#effects = effects;
		this.#identitySeed = unhex(disk.identitySeed, IDENTITY_BYTES, "identity seed");
		this.#sessionEntropy = unhex(disk.sessionEntropy, ENTROPY_BYTES, "publication entropy");
	}

	get identitySeed(): Uint8Array<ArrayBuffer> {
		return this.#identitySeed.slice();
	}

	get sessionEntropy(): Uint8Array<ArrayBuffer> {
		return this.#sessionEntropy.slice();
	}

	static async open(
		directory: string,
		applyResult?: RoomsSessionResultApplier,
		validateResult?: RoomsSessionResultValidator,
	): Promise<DurableRoomsSessionState> {
		const { disk, effects } = await openSessionStorage(directory);
		const state = new DurableRoomsSessionState(directory, disk, effects);
		if (validateResult != null) {
			for (const effect of effects.pending) {
				if (effect.type === "result") validateResult(disk.checkpoint, effect.resultKind, effect.intent);
			}
		}
		await state.#recoverResultEffects(applyResult);
		return state;
	}

	snapshot(): { revision: number; checkpoint: RoomsSessionState } {
		return { revision: this.#disk.revision, checkpoint: this.#disk.checkpoint };
	}

	get workspaceAdoption(): DiskState["workspaceAdoption"] {
		return this.#disk.workspaceAdoption;
	}

	pendingEffectIds(): string[] {
		return this.#effects.pending.map((operation) => operation.id);
	}

	pendingEffectDetails(): PendingEffectDetail[] {
		return this.#effects.pending.map((operation) =>
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

	pendingResultEffect(operationId: string): PendingEffectDetail & { result: string | null } {
		const pending = this.#effects.pending.find((operation) => operation.id === operationId);
		if (pending?.type !== "result") throw new Error("session has no result-bearing effect with that operation id");
		return {
			id: pending.id,
			kind: pending.resultKind,
			phase: pending.marker != null ? "applied" : pending.result != null ? "completed" : "prepared",
			intent: pending.intent,
			result: pending.result,
		};
	}

	operationKnown(operationId: string): boolean {
		return this.#disk.recent.some((operation) => operation.id === operationId) ||
			this.#effects.recent.some((operation) => operation.id === operationId) ||
			this.#effects.pending.some((operation) => operation.id === operationId);
	}

	onChange(changed: (revision: number, checkpoint: RoomsSessionState) => void): () => void {
		return this.#observers.onState(changed);
	}

	/** Observe durable checkpoint commits only. Effect-ledger transitions use
	 * `onChange` for attached-view status but do not ask the runtime to reconcile
	 * an unchanged workspace. */
	onCheckpointChange(
		changed: (revision: number, checkpoint: RoomsSessionState, impact: RoomsCheckpointImpact) => void,
	): () => void {
		return this.#observers.onCheckpoint(changed);
	}

	replace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		return this.mutate({
			operationId,
			baseRevision,
			material: JSON.stringify(checkpoint),
			impact: "realization",
			change: () => checkpoint,
		});
	}

	adoptWorkspace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		return this.mutate({
			operationId,
			baseRevision,
			material: JSON.stringify(["adoptWorkspace", checkpoint]),
			impact: "realization",
			change: () => acceptInitialWorkspace(this.#disk.workspaceAdoption, checkpoint),
		});
	}

	mutate(mutation: RoomsSessionMutation): Promise<number> {
		const run = this.#tail.then(() => this.#mutate(mutation));
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	prepareEffect(
		operationId: string,
		baseRevision: number,
		operationMaterial: string,
		preflight?: () => void,
	): Promise<{ kind: "prepared" } | { kind: "committed"; revision: number }> {
		const run = this.#tail.then(() => this.#prepareEffect(operationId, baseRevision, operationMaterial, preflight));
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	inspectEffect(
		operationId: string,
		baseRevision: number,
		operationMaterial: string,
	): Promise<OrdinaryEffectInspection> {
		const run = this.#tail.then(() => this.#inspectEffect(operationId, baseRevision, operationMaterial));
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	prepareInspectedEffect(
		inspection: NewOrdinaryEffectInspection,
		operationMaterial: string,
		preflight: () => void,
	): Promise<{ kind: "prepared" } | { kind: "committed"; revision: number }> {
		if (inspection[ordinaryEffectInspection] !== true || inspection.owner !== this.#inspectionOwner) {
			return Promise.reject(new Error("effect inspection does not belong to this state owner"));
		}
		const run = this.#tail.then(async () => {
			if (await textDigest(operationMaterial) !== inspection.digest) {
				throw new Error("session operation id was reused for a different command");
			}
			return await this.#prepareEffect(inspection.operationId, this.#disk.revision, operationMaterial, preflight);
		});
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	prepareResultEffect(
		operationId: string,
		baseRevision: number,
		operationMaterial: string,
		resultKind: string,
		intent: string,
	): Promise<
		| { kind: "prepared" }
		| { kind: "result"; result: string }
		| { kind: "committed"; revision: number; result: string }
	> {
		const run = this.#tail.then(() =>
			this.#prepareResultEffect(operationId, baseRevision, operationMaterial, resultKind, intent)
		);
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	commitEffect(operationId: string, operationMaterial: string): Promise<number> {
		const run = this.#tail.then(() => this.#commitEffect(operationId, operationMaterial));
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	commitResultEffect(
		operationId: string,
		operationMaterial: string,
		result: string,
		applyResult: RoomsSessionResultApplier,
	): Promise<number> {
		const run = this.#tail.then(() =>
			this.#commitResultEffect(operationId, operationMaterial, result, applyResult)
		);
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	commitPendingResultEffect(
		operationId: string,
		result: string,
		applyResult: RoomsSessionResultApplier,
	): Promise<number> {
		const run = this.#tail.then(() => this.#commitPendingResultEffect(operationId, result, applyResult));
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<void> {
		const run = this.#tail.then(() => this.#resolveEffect(operationId, outcome));
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	async #prepareEffect(
		operationId: string,
		baseRevision: number,
		operationMaterial: string,
		preflight?: () => void,
	): Promise<{ kind: "prepared" } | { kind: "committed"; revision: number }> {
		const inspected = await this.#inspectEffect(operationId, baseRevision, operationMaterial);
		if (inspected.kind === "committed") return inspected;
		preflight?.();
		if (this.#effects.pending.length === PENDING_OPERATIONS) {
			throw new Error("session pending-operation ledger is full");
		}
		const next = {
			...this.#effects,
			pending: [
				...this.#effects.pending,
				{
					type: "ordinary" as const,
					id: operationId,
					digest: inspected.digest,
					subject: describeOrdinaryEffect(operationMaterial),
				},
			],
		};
		await writeEffects(this.#directory, next);
		this.#effects = next;
		this.#notifyChanged();
		return { kind: "prepared" };
	}

	async #inspectEffect(
		operationId: string,
		baseRevision: number,
		operationMaterial: string,
	): Promise<OrdinaryEffectInspection> {
		const inspected = await inspectOrdinaryEffect(
			this.#disk,
			this.#effects,
			operationId,
			baseRevision,
			operationMaterial,
		);
		if (inspected.kind === "committed") return inspected;
		return {
			kind: "new",
			operationId,
			digest: inspected.digest,
			owner: this.#inspectionOwner,
			[ordinaryEffectInspection]: true,
		};
	}

	async #prepareResultEffect(
		operationId: string,
		baseRevision: number,
		operationMaterial: string,
		resultKind: string,
		intent: string,
	): Promise<
		| { kind: "prepared" }
		| { kind: "result"; result: string }
		| { kind: "committed"; revision: number; result: string }
	> {
		validateOperationId(operationId);
		resultKind = effectKind(resultKind);
		intent = effectText(intent, "result intent");
		const operationDigest = await textDigest(operationMaterial);
		if (this.#disk.recent.some((operation) => operation.id === operationId)) {
			throw new Error("session operation id is already used by a checkpoint command");
		}
		const committed = this.#effects.recent.find((operation) => operation.id === operationId);
		if (committed != null) {
			if (committed.digest !== operationDigest || committed.resultKind !== resultKind) {
				throw new Error("session operation id was reused for a different command");
			}
			if (committed.outcome === "abandoned") {
				throw new Error("session operation was abandoned and cannot be retried");
			}
			if (committed.result == null) throw new Error("session committed result is missing its authority");
			return { kind: "committed", revision: committed.revision, result: committed.result };
		}
		const pending = this.#effects.pending.find((operation) => operation.id === operationId);
		if (pending != null) {
			if (
				pending.type !== "result" || pending.digest !== operationDigest || pending.resultKind !== resultKind ||
				pending.baseRevision !== baseRevision || pending.intent !== intent
			) throw new Error("session operation id was reused for a different command");
			return pending.result == null ? { kind: "prepared" } : { kind: "result", result: pending.result };
		}
		if (this.#effects.pending.some((operation) => operation.type === "result")) {
			throw new Error("session already has a result-bearing effect in flight");
		}
		if (baseRevision !== this.#disk.revision) {
			throw new Error(`session revision changed from ${baseRevision} to ${this.#disk.revision}`);
		}
		if (this.#effects.pending.length === PENDING_OPERATIONS) {
			throw new Error("session pending-operation ledger is full");
		}
		const next: EffectsState = {
			...this.#effects,
			pending: [...this.#effects.pending, {
				type: "result",
				id: operationId,
				digest: operationDigest,
				resultKind,
				baseRevision,
				intent,
				result: null,
				marker: null,
			}],
		};
		await writeEffects(this.#directory, next);
		this.#effects = next;
		this.#notifyChanged();
		return { kind: "prepared" };
	}

	async #commitEffect(operationId: string, operationMaterial: string): Promise<number> {
		const operationDigest = await textDigest(operationMaterial);
		const at = this.#effects.pending.findIndex((operation) => operation.id === operationId);
		if (
			at < 0 || this.#effects.pending[at].type !== "ordinary" ||
			this.#effects.pending[at].digest !== operationDigest
		) {
			throw new Error("session effect has no matching durable reservation");
		}
		const revision = this.#disk.revision;
		const next = {
			...this.#effects,
			pending: this.#effects.pending.filter((_, index) => index !== at),
			recent: [
				{
					id: operationId,
					digest: operationDigest,
					revision,
					outcome: "committed" as const,
					resultKind: null,
					result: null,
				},
				...this.#effects.recent,
			]
				.slice(0, RECENT_OPERATIONS),
		};
		await writeEffects(this.#directory, next);
		this.#effects = next;
		this.#notifyChanged();
		return revision;
	}

	async #commitResultEffect(
		operationId: string,
		operationMaterial: string,
		result: string,
		applyResult: RoomsSessionResultApplier,
	): Promise<number> {
		result = effectText(result, "result value");
		const operationDigest = await textDigest(operationMaterial);
		const at = this.#effects.pending.findIndex((operation) => operation.id === operationId);
		if (at < 0) {
			const committed = this.#effects.recent.find((operation) => operation.id === operationId);
			if (
				committed?.outcome === "committed" && committed.digest === operationDigest &&
				committed.result === result
			) return committed.revision;
			throw new Error("session result effect has no matching durable reservation");
		}
		const pending = this.#effects.pending[at];
		if (pending.type !== "result" || pending.digest !== operationDigest) {
			throw new Error("session result effect has no matching durable reservation");
		}
		return await this.#storeAndApplyResult(pending, result, applyResult);
	}

	async #commitPendingResultEffect(
		operationId: string,
		result: string,
		applyResult: RoomsSessionResultApplier,
	): Promise<number> {
		const pending = this.#effects.pending.find((operation) => operation.id === operationId);
		if (pending?.type !== "result") throw new Error("session has no result-bearing effect with that operation id");
		return await this.#storeAndApplyResult(pending, result, applyResult);
	}

	async #storeAndApplyResult(
		pending: PendingResultEffect,
		result: string,
		applyResult: RoomsSessionResultApplier,
	): Promise<number> {
		result = effectText(result, "result value");
		if (pending.result != null && pending.result !== result) {
			throw new Error("session result effect changed its returned authority");
		}
		if (pending.result == null) {
			pending = { ...pending, result };
			const completed: EffectsState = {
				...this.#effects,
				pending: this.#effects.pending.map((operation) => operation.id === pending.id ? pending : operation),
			};
			await writeEffects(this.#directory, completed);
			this.#effects = completed;
		}
		return await this.#applyResultEffect(pending, applyResult, true);
	}

	async #recoverResultEffects(applyResult?: RoomsSessionResultApplier): Promise<void> {
		const pending = this.#effects.pending.find((operation) => operation.type === "result");
		if (pending == null || pending.result == null) return;
		if (applyResult == null) throw new Error("Rooms session has a result effect but no recovery applier");
		await this.#applyResultEffect(pending, applyResult, false);
	}

	async #applyResultEffect(
		pending: PendingResultEffect,
		applyResult: RoomsSessionResultApplier,
		notify: boolean,
	): Promise<number> {
		if (pending.result == null) throw new Error("session result effect has no returned authority");
		const result = pending.result;
		const resultDigest = await textDigest(result);
		let marker = pending.marker;
		let candidate: RoomsSessionState | null = null;
		if (marker == null) {
			if (this.#disk.revision < pending.baseRevision) {
				throw new Error("session result base is ahead of the current checkpoint");
			}
			if (this.#disk.revision === Number.MAX_SAFE_INTEGER) throw new Error("session revision is exhausted");
			candidate = applyResult(
				this.#disk.checkpoint,
				pending.resultKind,
				pending.intent,
				result,
			);
			const parsed = z.safeParse(RoomsSessionStateSchema, candidate);
			if (!parsed.success) throw new Error("session result would produce an invalid checkpoint");
			candidate = freezeCheckpoint(parsed.data);
			marker = {
				revision: this.#disk.revision + 1,
				applyKind: pending.resultKind,
				resultDigest,
			};
			pending = { ...pending, marker };
			const marked: EffectsState = {
				...this.#effects,
				pending: this.#effects.pending.map((operation) => operation.id === pending.id ? pending : operation),
			};
			await writeEffects(this.#directory, marked);
			this.#effects = marked;
		} else if (marker.resultDigest !== resultDigest) {
			throw new Error("session result marker does not name its returned authority");
		}

		if (this.#disk.revision === marker.revision - 1) {
			if (candidate == null) {
				candidate = applyResult(
					this.#disk.checkpoint,
					marker.applyKind,
					pending.intent,
					result,
				);
				const parsed = z.safeParse(RoomsSessionStateSchema, candidate);
				if (!parsed.success) throw new Error("session result would produce an invalid checkpoint");
				candidate = freezeCheckpoint(parsed.data);
			}
			const next: DiskState = {
				...this.#disk,
				revision: marker.revision,
				workspaceAdoption: "closed",
				checkpoint: candidate,
			};
			await write(this.#directory, next);
			this.#disk = next;
			if (notify) this.#notifyCheckpointChanged("realization");
		} else if (this.#disk.revision === marker.revision) {
			const reapplied = applyResult(
				this.#disk.checkpoint,
				marker.applyKind,
				pending.intent,
				result,
			);
			const parsed = z.safeParse(RoomsSessionStateSchema, reapplied);
			if (!parsed.success || JSON.stringify(parsed.data) !== JSON.stringify(this.#disk.checkpoint)) {
				throw new Error("session result marker does not match its checkpoint");
			}
		} else {
			throw new Error("session result marker is not adjacent to its checkpoint revision");
		}

		const finalized: EffectsState = {
			...this.#effects,
			pending: this.#effects.pending.filter((operation) => operation.id !== pending.id),
			recent: [{
				id: pending.id,
				digest: pending.digest,
				revision: marker.revision,
				outcome: "committed" as const,
				resultKind: pending.resultKind,
				result,
			}, ...this.#effects.recent].slice(0, RECENT_OPERATIONS),
		};
		await writeEffects(this.#directory, finalized);
		this.#effects = finalized;
		if (notify) this.#notifyChanged();
		return marker.revision;
	}

	async #resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<void> {
		const at = this.#effects.pending.findIndex((operation) => operation.id === operationId);
		if (at < 0) throw new Error("session has no unresolved effect with that operation id");
		const pending = this.#effects.pending[at];
		if (pending.type === "result" && (outcome !== "abandoned" || pending.result != null)) {
			throw new Error("a result-bearing effect can only be abandoned before it returns authority");
		}
		const next = {
			...this.#effects,
			pending: this.#effects.pending.filter((_, index) => index !== at),
			recent: [{
				id: pending.id,
				digest: pending.digest,
				revision: this.#disk.revision,
				outcome,
				resultKind: pending.type === "result" ? pending.resultKind : null,
				result: null,
			}, ...this.#effects.recent]
				.slice(0, RECENT_OPERATIONS),
		};
		await writeEffects(this.#directory, next);
		this.#effects = next;
		this.#notifyChanged();
	}

	async #mutate(mutation: RoomsSessionMutation): Promise<number> {
		const { operationId, baseRevision, material: operationMaterial, impact, change } = mutation;
		validateOperationId(operationId);
		const operationDigest = await textDigest(operationMaterial);
		const repeated = this.#disk.recent.find((operation) => operation.id === operationId);
		if (repeated != null) {
			if (repeated.digest !== operationDigest) {
				throw new Error("session operation id was reused for a different command");
			}
			return repeated.revision;
		}
		const effect = this.#effects.recent.find((operation) => operation.id === operationId) ??
			this.#effects.pending.find((operation) => operation.id === operationId);
		if (effect != null) throw new Error("session operation id is already used by an external effect");
		if (baseRevision !== this.#disk.revision) {
			throw new Error(`session revision changed from ${baseRevision} to ${this.#disk.revision}`);
		}
		if (this.#disk.revision === Number.MAX_SAFE_INTEGER) throw new Error("session revision is exhausted");
		const candidate = change(this.#disk.checkpoint);
		const parsed = z.safeParse(RoomsSessionStateSchema, candidate);
		if (!parsed.success) throw new Error("session command would produce an invalid checkpoint");
		const checkpoint = freezeCheckpoint(parsed.data);
		const revision = this.#disk.revision + 1;
		const next: DiskState = {
			...this.#disk,
			revision,
			workspaceAdoption: "closed",
			checkpoint,
			recent: [{ id: operationId, digest: operationDigest, revision }, ...this.#disk.recent]
				.slice(0, RECENT_OPERATIONS),
		};
		await write(this.#directory, next);
		this.#disk = next;
		this.#notifyCheckpointChanged(impact);
		return revision;
	}

	#notifyChanged(): void {
		this.#observers.stateChanged(this.#disk.revision, this.#disk.checkpoint);
	}

	#notifyCheckpointChanged(impact: RoomsCheckpointImpact): void {
		this.#observers.checkpointChanged(this.#disk.revision, this.#disk.checkpoint, impact);
	}
}
