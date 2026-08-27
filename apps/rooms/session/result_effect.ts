// Result-bearing command execution and explicit recovery.

import { applyRoomsSessionResult, prepareRoomsSessionResult, resumeRoomsSessionResult } from "./commands.ts";
import type { DurableRoomsRuntime } from "./runtime.ts";
import type { DurableRoomsSessionState } from "./state.ts";

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
			if (plan.kind === "private-room") {
				if (plan.directory == null || plan.recoveryKey == null) {
					throw new Error("private-room result plan is incomplete");
				}
				result = JSON.stringify(await runtime.openPrivateRoom(plan.directory, plan.recoveryKey));
			} else if (plan.kind === "room-link") {
				if (plan.conversationId == null) throw new Error("room-link result plan is incomplete");
				result = JSON.stringify({ roomLink: await runtime.ensureRoomLink(plan.conversationId) });
			} else {
				if (plan.conversationId == null) throw new Error("room-moderator result plan is incomplete");
				result = await runtime.takeRoomModerator(plan.conversationId, plan.stewardLink ?? null);
			}
		} catch (error) {
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
		if (plan.kind === "private-room") {
			if (plan.directory == null || plan.recoveryKey == null) {
				throw new Error("private-room result plan is incomplete");
			}
			result = JSON.stringify(await runtime.openPrivateRoom(plan.directory, plan.recoveryKey));
		} else if (plan.kind === "room-link") {
			if (plan.conversationId == null) throw new Error("room-link result plan is incomplete");
			result = JSON.stringify({ roomLink: await runtime.ensureRoomLink(plan.conversationId) });
		} else {
			if (plan.conversationId == null) throw new Error("room-moderator result plan is incomplete");
			result = await runtime.takeRoomModerator(plan.conversationId, plan.stewardLink ?? null);
		}
	}
	return await state.commitPendingResultEffect(operationId, result, applyRoomsSessionResult);
}
