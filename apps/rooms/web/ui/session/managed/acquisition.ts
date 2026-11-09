// A proved conflict or a refusal settles an acquisition and frees its request.
// Only a conflict permits re-preparation, and only an outcome nothing settled
// keeps the request for replay.
import { managedSessionText } from "../../../../lib/text/managed_session.ts";
import type { OperationsCapability } from "../../application_data.ts";

// A proved conflict installed no custody, so re-preparation at a newer
// revision is safe. The bound settles an unstable workspace as a refusal
// instead of an unbounded gesture.
export const MAX_CONFLICT_REPREPARATIONS = 4;

export class AcquisitionConflict extends Error {
	constructor() {
		super(managedSessionText.acquisitionConflict);
	}
}

/** An acquisition the session answered with a refusal: it admitted nothing,
 * so the request is settled and freed. The message is the session's reason. */
export class AcquisitionRefused extends Error {}

/** An outcome that settled the request, which its holder then frees: a
 * committed or refused request has nothing left to replay, and a conflict is
 * replayed only through re-preparation. */
export type SettledOutcome = {
	readonly status: "committed" | "conflict" | "refused";
	readonly reason?: string;
};

/** What Rust reports for a submitted request: a settled outcome, or one
 * nothing settled, which keeps the request for replay. */
export type SubmissionOutcome = SettledOutcome | { readonly status: "uncertain"; readonly reason?: string };

/** Submit a prepared acquisition. An outcome Rust could not settle throws, and
 * the holder keeps the request. */
export async function submitAcquisition(request: { submit(): Promise<SubmissionOutcome> }): Promise<SettledOutcome> {
	const outcome = await request.submit();
	if (outcome.status !== "uncertain") return outcome;
	const { reason } = outcome;
	throw new Error(
		reason == null ? managedSessionText.acquisitionUnknown : `${managedSessionText.acquisitionUnknown} (${reason})`,
	);
}

/** A settled outcome as its holder's caller sees it, once the request is
 * freed: a committed one returns, a conflict throws `AcquisitionConflict`,
 * and a refusal throws `AcquisitionRefused` with the session's reason. */
export function throwUnlessCommitted(outcome: SettledOutcome): void {
	if (outcome.status === "conflict") throw new AcquisitionConflict();
	if (outcome.status === "refused") {
		throw new AcquisitionRefused(outcome.reason ?? managedSessionText.acquisitionRefused);
	}
}

/** An operations acquisition the session refused, one failure per capability it would not hand over. */
export class OperationsAcquisitionRefused extends Error {
	constructor(
		readonly failures: readonly { capability: OperationsCapability; reason: string; advice: string | null }[],
	) {
		super(managedSessionText.operationsAcquisitionRefused);
	}
}
