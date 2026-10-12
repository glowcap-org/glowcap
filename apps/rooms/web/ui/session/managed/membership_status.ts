// Supervisor reports are snapshots. Only a new failure is a journal event.
import * as store from "../../store.ts";
import type { PageProjection } from "../../store/core.ts";
import { dirId } from "../../types.ts";
import { managedSessionText as text } from "../../../../lib/text/managed_session.ts";
import {
	type ActionRefusal,
	admissionRefusal,
	clearRefusal,
	joinRefusalKeys,
	rememberJoinRefusal,
} from "../../admission_feedback.ts";
import { refusalText } from "../../../../lib/text/failure.ts";

type Failure = { target: { kind: string; id: string }; reason: string };
export type MembershipStatus = { failures?: readonly Failure[]; sourceFailure?: string };

function destination(projection: PageProjection, target: Failure["target"]): ActionRefusal["target"] | null {
	if (target.kind === "directory") return { directory: target.id, room: "" };
	if (target.kind !== "room") return null;
	const room = store.convByPersistId(projection, target.id);
	return room?.type === "room" ? { directory: room.dir, room: room.id } : null;
}

/** One prior failure map borrows the last report's bounded scalar strings.
 * Membership limits bound its entries. Each next report replaces it. Retaining
 * this projection prevents unrelated workspace wakes from filling the journal
 * with unchanged failures. Clearing a failure allows a later recurrence. */
export function membershipStatus(
	projection: PageProjection,
	report: (source: string, error: unknown) => void,
): (state: MembershipStatus) => void {
	let previous = new Map<string, string>();
	let feedback = new Map<string, ActionRefusal>();
	let sourceFailure: string | undefined;
	return (state) => {
		const current = new Map<string, string>();
		const nextFeedback = new Map<string, ActionRefusal>();
		for (const failure of state.failures ?? []) {
			const key = `${failure.target.kind}:${failure.target.id}`;
			current.set(key, failure.reason);
			if (previous.get(key) !== failure.reason) report(text.roomsConnection, failure.reason);
			const refusal = admissionRefusal(failure.reason);
			if (refusal != null) {
				const target = destination(projection, failure.target);
				if (target != null) {
					const keys = joinRefusalKeys(target.directory, target.room);
					const action = keys[refusal.retryScope === "room-join" ? 1 : 0];
					if (previous.get(key) === failure.reason) {
						// An unchanged snapshot cannot renew advice or claim a newer
						// gesture's feedback. Retain only this report's exact object.
						const owned = feedback.get(action);
						if (owned != null) nextFeedback.set(action, owned);
					} else {
						const before = projection.get().actionRefusals.get(action);
						rememberJoinRefusal(projection, target.directory, target.room, refusal);
						const after = projection.get().actionRefusals.get(action)!;
						const shared = feedback.get(action) === after || nextFeedback.get(action) === after;
						if (before !== after || shared) nextFeedback.set(action, after);
					}
				}
			}
			if (failure.target.kind === "directory") {
				const id = dirId(failure.target.id);
				if (projection.get().dirs.has(id)) {
					store.patchDir(projection, id, {
						session: "disconnected",
						statusText: refusal == null ? text.directoryUnavailable : refusalText(refusal),
					});
				}
			}
		}
		previous = current;
		for (const [action, owned] of feedback) {
			if (!nextFeedback.has(action) && projection.get().actionRefusals.get(action) === owned) {
				clearRefusal(projection, action);
			}
		}
		feedback = nextFeedback;
		if (state.sourceFailure != null && state.sourceFailure !== sourceFailure) {
			report(text.workspaceAccess, state.sourceFailure);
		}
		sourceFailure = state.sourceFailure;
	};
}
