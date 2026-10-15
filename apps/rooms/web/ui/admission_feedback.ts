// Refusal stays beside the action that caused it. A cooldown schedules no work:
// expiry only enables another explicit gesture. Each page owns its bounded map.
import { RoomsError, roomsErrorInMessage } from "../../lib/error_codes.ts";
import { refusalText } from "../../lib/text/failure.ts";
import type { PageProjection } from "./store/core.ts";

/** Refusals one page keeps, oldest dropped first. */
const MAX_ACTION_REFUSALS = 512;

export interface ActionRefusal {
	readonly text: string;
	readonly failure: RoomsError;
	readonly target?: { directory: string; room: string };
	readonly until: number | null;
}

export function remaining(refusal: ActionRefusal | undefined, now = performance.now()): number {
	return refusal?.until == null ? 0 : Math.max(0, Math.ceil((refusal.until - now) / 1000));
}

export function admissionRefusal(error: unknown): RoomsError | null {
	const typed = roomsErrorInMessage(error);
	return typed != null && ["rate-limited", "admission-busy", "request-too-large"].includes(typed.code) ? typed : null;
}

export function rememberRefusal(
	projection: PageProjection,
	action: string,
	error: unknown,
	target?: ActionRefusal["target"],
): boolean {
	const typed = admissionRefusal(error);
	if (typed == null) return false;
	const before = projection.get().actionRefusals;
	// Repeated clicks cannot extend a cooldown that already belongs to this act.
	if (remaining(before.get(action)) !== 0) return true;
	const delay = typed.retryAfterMs;
	const next = new Map(before);
	if (!next.has(action) && next.size >= MAX_ACTION_REFUSALS) next.delete(next.keys().next().value!);
	next.set(action, {
		text: refusalText(error),
		failure: typed,
		target,
		until: delay == null ? null : performance.now() + delay,
	});
	projection.set({ actionRefusals: next });
	return true;
}

export function clearRefusal(projection: PageProjection, action: string): void {
	if (!projection.get().actionRefusals.has(action)) return;
	const next = new Map(projection.get().actionRefusals);
	next.delete(action);
	projection.set({ actionRefusals: next });
}

export function joinRefusalKeys(directory: string, room: string): readonly string[] {
	return ["join:" + directory, "join:" + JSON.stringify([directory, room.toLowerCase()])];
}
export function rememberJoinRefusal(
	projection: PageProjection,
	directory: string,
	room: string,
	error: unknown,
): boolean {
	const typed = roomsErrorInMessage(error);
	const keys = joinRefusalKeys(directory, room);
	return rememberRefusal(projection, typed?.retryScope === "room-join" ? keys[1] : keys[0], error, {
		directory,
		room,
	});
}
export function activeRefusal(
	refusals: ReadonlyMap<string, ActionRefusal>,
	actions: string | readonly string[],
	now = performance.now(),
): ActionRefusal | undefined {
	const keys = typeof actions === "string" ? [actions] : actions;
	let result: ActionRefusal | undefined;
	for (const key of keys) {
		const candidate = refusals.get(key);
		if (candidate != null && (result == null || remaining(candidate, now) > remaining(result, now))) {
			result = candidate;
		}
	}
	return result;
}
