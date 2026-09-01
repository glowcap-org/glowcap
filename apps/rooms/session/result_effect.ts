// Result-bearing command execution and explicit recovery.

import { applyRoomsSessionResult, prepareRoomsSessionResult, resumeRoomsSessionResult } from "./result_commands.ts";
import { ROOM_RETIRED, roomErrorOf } from "../lib/errors.ts";
import type { DurableRoomsRuntime } from "./runtime.ts";
import type { DurableRoomsSessionState } from "./state.ts";

/** One live durable-session runtime coalesces retries of the same result plan.
 * The disk row survives process loss; this map covers the narrower interval in
 * which another attached client can observe that row while its original Host
 * call is still executing. Joining that call prevents a recovery request from
 * re-entering the Host, without turning process-local state into authority. */
export class ResultEffectCoordinator {
	readonly #active = new Map<string, { material: string | null; run: Promise<number> }>();

	run(operationId: string, material: string | null, work: () => Promise<number>): Promise<number> {
		const active = this.#active.get(operationId);
		if (active != null) {
			if (material != null && active.material == null) {
				return Promise.reject(new Error("session result recovery is already in flight"));
			}
			if (material != null && material !== active.material) {
				return Promise.reject(new Error("session operation id was reused for a different result command"));
			}
			return active.run;
		}
		const run = Promise.resolve().then(work);
		this.#active.set(operationId, { material, run });
		void run.then(
			() => {
				if (this.#active.get(operationId)?.run === run) this.#active.delete(operationId);
			},
			() => {
				if (this.#active.get(operationId)?.run === run) this.#active.delete(operationId);
			},
		);
		return run;
	}
}

async function realizeResult(
	runtime: DurableRoomsRuntime,
	plan: ReturnType<typeof prepareRoomsSessionResult>,
): Promise<string> {
	if (plan.kind === "managed-room") {
		if (plan.directory == null || plan.recoveryKey == null || plan.policy == null) {
			throw new Error("managed-room result plan is incomplete");
		}
		if (plan.label == null) throw new Error("managed-room result plan has no label");
		return JSON.stringify(
			await runtime.roomActions.openManaged(plan.directory, plan.label, plan.recoveryKey, plan.policy),
		);
	}
	if (plan.kind === "room-link") {
		if (plan.conversationId == null) throw new Error("room-link result plan is incomplete");
		return JSON.stringify({ roomLink: await runtime.roomActions.ensureLink(plan.conversationId) });
	}
	if (plan.kind === "room-manager") {
		if (plan.conversationId == null) throw new Error("room-manager result plan is incomplete");
		return plan.managerLink == null
			? await runtime.roomActions.recoverManager(plan.conversationId)
			: await runtime.roomActions.takeManager(plan.conversationId, plan.managerLink);
	}
	if (plan.conversationId == null) throw new Error("room-moderator result plan is incomplete");
	return await runtime.roomActions.takeModerator(plan.conversationId, plan.stewardLink ?? null);
}

export async function performResultCommand(
	state: DurableRoomsSessionState,
	runtime: DurableRoomsRuntime,
	operationId: string,
	baseRevision: number,
	command: string,
	args: string[],
	operationMaterial: string,
): Promise<number> {
	const plan = prepareRoomsSessionResult(
		state.snapshot().checkpoint,
		command,
		args,
		state.operationKnown(operationId),
	);
	if (plan.kind === "room-manager" && plan.managerLink == null) {
		runtime.roomActions.assertManagerRecoverable(plan.conversationId ?? "");
	}
	const admission = await state.prepareResultEffect(
		operationId,
		baseRevision,
		operationMaterial,
		plan.kind,
		plan.intent,
	);
	if (admission.kind === "committed") return admission.revision;
	let result: string;
	if (admission.kind === "result") result = admission.result;
	else {
		try {
			result = await realizeResult(runtime, plan);
		} catch (error) {
			if (roomErrorOf(error)?.code === ROOM_RETIRED) {
				await state.resolveEffect(operationId, "abandoned");
				throw new Error(
					"That room publication was retired. Its unfinished capability operation was abandoned; use the room's source authority instead.",
				);
			}
			throw new Error(
				`Rooms authority operation did not complete; its recovery operation can be resumed safely: ${
					error instanceof Error ? error.message : error
				}`,
			);
		}
	}
	return await state.commitResultEffect(operationId, operationMaterial, result, applyRoomsSessionResult);
}

export async function resumeResultEffect(
	state: DurableRoomsSessionState,
	runtime: DurableRoomsRuntime,
	operationId: string,
): Promise<number> {
	const pending = state.pendingResultEffect(operationId);
	if (pending.intent == null) throw new Error("the result effect has no durable intent");
	const plan = resumeRoomsSessionResult(state.snapshot().checkpoint, pending.kind, pending.intent);
	let result = pending.result;
	if (result == null) {
		try {
			result = await realizeResult(runtime, plan);
		} catch (error) {
			if (roomErrorOf(error)?.code !== ROOM_RETIRED) throw error;
			await state.resolveEffect(operationId, "abandoned");
			return state.snapshot().revision;
		}
	}
	return await state.commitPendingResultEffect(operationId, result, applyRoomsSessionResult);
}
