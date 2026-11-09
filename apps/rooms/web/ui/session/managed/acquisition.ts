// Only an explicit acquisition conflict proves absence of custody acquisition.
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

/** An acquisition the session answered with a refusal, so it admitted nothing
 * and the request has no replay value. The message is the session's reason. */
export class AcquisitionRefused extends Error {}

/** What Rust reports for a submitted request: committed, a proved conflict,
 * a refusal that admitted nothing, or an outcome nothing settled. */
export type SubmissionOutcome = {
	readonly status: "committed" | "conflict" | "refused" | "uncertain";
	readonly reason?: string;
};

function submissionOutcome(value: unknown): SubmissionOutcome | null {
	if (typeof value !== "object" || value == null || !("status" in value)) return null;
	const { status } = value;
	if (status !== "committed" && status !== "conflict" && status !== "refused" && status !== "uncertain") return null;
	const reason = "reason" in value && typeof value.reason === "string" ? value.reason : undefined;
	return { status, reason };
}

/** Submit a prepared acquisition. A refusal throws `AcquisitionRefused`, and
 * any outcome Rust could not settle throws so the caller keeps the request. */
export async function submitAcquisition(request: { submit(): Promise<unknown> }): Promise<"committed" | "conflict"> {
	const outcome = submissionOutcome(await request.submit());
	if (outcome?.status === "committed" || outcome?.status === "conflict") return outcome.status;
	if (outcome?.status === "refused") {
		throw new AcquisitionRefused(outcome.reason ?? managedSessionText.acquisitionRefused);
	}
	const reason = outcome?.reason;
	throw new Error(
		reason == null ? managedSessionText.acquisitionUnknown : `${managedSessionText.acquisitionUnknown} (${reason})`,
	);
}

/** An operations acquisition the session refused, one failure per capability it would not hand over. */
export class OperationsAcquisitionRefused extends Error {
	constructor(
		readonly failures: readonly { capability: OperationsCapability; reason: string; advice: string | null }[],
	) {
		super(managedSessionText.operationsAcquisitionRefused);
	}
}
