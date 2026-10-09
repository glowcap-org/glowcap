// Supervisor reports are snapshots. Only a new failure is a journal event.
import * as store from "../../store.ts";
import type { PageProjection } from "../../store/core.ts";
import { dirId } from "../../types.ts";
import { managedSessionText as text } from "../../../../lib/text/managed_session.ts";

type Failure = { target: { kind: string; id: string }; reason: string };
export type MembershipStatus = { failures?: readonly Failure[]; sourceFailure?: string };

/** One prior failure map borrows the last report's bounded scalar strings.
 * Membership limits bound its entries; each next report replaces it. Retaining
 * this projection prevents unrelated workspace wakes from filling the journal
 * with unchanged failures. Clearing a failure allows a later recurrence. */
export function membershipStatus(
	projection: PageProjection,
	report: (source: string, error: unknown) => void,
): (state: MembershipStatus) => void {
	let previous = new Map<string, string>();
	let sourceFailure: string | undefined;
	return (state) => {
		const current = new Map<string, string>();
		for (const failure of state.failures ?? []) {
			const key = `${failure.target.kind}:${failure.target.id}`;
			current.set(key, failure.reason);
			if (previous.get(key) !== failure.reason) report(text.roomsConnection, failure.reason);
			if (failure.target.kind === "directory") {
				const id = dirId(failure.target.id);
				if (projection.get().dirs.has(id)) {
					store.patchDir(projection, id, { session: "disconnected", statusText: text.directoryUnavailable });
				}
			}
		}
		previous = current;
		if (state.sourceFailure != null && state.sourceFailure !== sourceFailure) {
			report(text.workspaceAccess, state.sourceFailure);
		}
		sourceFailure = state.sourceFailure;
	};
}
