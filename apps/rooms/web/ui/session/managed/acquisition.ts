// A proved conflict or a refusal settles a submitted acquisition or session
// command and frees its request. Only a conflict permits re-preparation, and
// only an outcome nothing settled keeps the request for replay.
import { invariant } from "../../../../lib/invariant.ts";
import { ReportedFailure } from "./reported_failure.ts";
import { LocalRefusal } from "../../../../lib/text/failure.ts";
type ConflictKey = "acquisition-conflict" | "access-issue-conflict" | "access-edit-conflict";
type UnknownKey = "acquisition-unknown" | "access-issue-unknown" | "access-edit-unknown";
import { managedSessionText } from "../../../../lib/text/managed_session.ts";
import type { OperationsCapability } from "../../application_data.ts";

// A proved conflict installed no custody, so re-preparation at a newer
// revision is safe. The bound settles an unstable workspace as a refusal
// instead of an unbounded gesture.
export const MAX_CONFLICT_REPREPARATIONS = 4;

export class AcquisitionConflict extends LocalRefusal {
	constructor(key: ConflictKey = "acquisition-conflict") {
		super(key);
	}
}

/** An acquisition or session command the session answered with a refusal: it
 * admitted nothing, so the request is settled and freed. The message is the
 * session's reason. */
export class SubmissionRefused extends ReportedFailure {}

/** An outcome that settled the request, which its holder then frees: a
 * committed or refused request has nothing left to replay, and a conflict is
 * replayed only through re-preparation. */
export type SettledOutcome = {
	readonly status: "committed" | "conflict" | "refused";
	readonly reason?: string;
	readonly failure?: unknown;
};

/** What Rust reports for a submitted request: a settled outcome, or one
 * nothing settled, which keeps the request for replay. */
export type SubmissionOutcome = SettledOutcome | {
	readonly status: "uncertain";
	readonly reason?: string;
	readonly failure?: unknown;
};

/** A session command the session settled: a proved conflict, a refusal that
 * admitted nothing, or the status of the receipt it admitted. */
type CommandAdmission =
	| { readonly status: "conflict" | "refused"; readonly reason?: string; readonly failure?: unknown }
	| { readonly status: "pending" | "committed" | "unsent" | "unknown" };

const ACQUISITION_STATUSES = ["committed", "conflict", "refused"] as const;
const COMMAND_STATUSES = ["conflict", "refused", "pending", "committed", "unsent", "unknown"] as const;

/** Read the Rust application's outcome. A reported uncertainty throws while
 * the holder keeps the request. An unrecognized answer violates the shared
 * application contract and cannot authorize another submission. */
function settledOutcome<S extends string>(value: unknown, statuses: readonly S[]): {
	readonly status: S;
	readonly reason?: string;
	readonly failure?: unknown;
} {
	const reason = `unrecognized outcome ${JSON.stringify(value) ?? String(value)}`;
	if (typeof value === "object" && value !== null) {
		const status = "status" in value ? value.status : undefined;
		const said = "reason" in value ? value.reason : undefined;
		const failure = "failure" in value ? value.failure : undefined;
		if (said == null || typeof said === "string") {
			const known = statuses.find((candidate) => candidate === status);
			if (known != null) return { status: known, reason: said ?? undefined, failure };
			if (status === "uncertain") throw submissionError({ status, reason: said ?? undefined });
		}
	}
	invariant(false, reason);
}

/** Submit a prepared acquisition. An outcome Rust could not settle throws, and
 * the holder keeps the request. */
export async function submitAcquisition(request: { submit(): Promise<unknown> }): Promise<SettledOutcome> {
	return settledOutcome(await request.submit(), ACQUISITION_STATUSES);
}

/** Submit a prepared session command. An outcome Rust could not settle throws,
 * and the holder keeps the request. */
export async function submitCommand(request: { submit(): Promise<unknown> }): Promise<CommandAdmission> {
	const outcome = settledOutcome(await request.submit(), COMMAND_STATUSES);
	return outcome.status === "conflict" || outcome.status === "refused" ? outcome : { status: outcome.status };
}

/** The error a submitted outcome exposes. Its holder keeps uncertain requests
 * and supplies the catalog key for recovering them on its own surface. */
export interface SubmissionFailureContext {
	readonly conflict: ConflictKey;
	readonly uncertain: UnknownKey;
}

export function submissionError(
	outcome: SubmissionOutcome,
	context?: SubmissionFailureContext,
): Error | null {
	switch (outcome.status) {
		case "committed":
			return null;
		case "conflict":
			return new AcquisitionConflict(context?.conflict);
		case "refused":
			return new SubmissionRefused(outcome.reason ?? managedSessionText.acquisitionRefused, outcome.failure);
		case "uncertain":
			return new LocalRefusal(context?.uncertain ?? "acquisition-unknown", { cause: outcome.reason });
	}
}

export function throwUnlessCommitted(outcome: SettledOutcome): void {
	const failure = submissionError(outcome);
	if (failure != null) throw failure;
}

/** An operations acquisition the session refused, one failure per capability it would not hand over. */
export class OperationsAcquisitionRefused extends LocalRefusal {
	constructor(
		readonly failures: readonly {
			capability: OperationsCapability;
			reason: string;
			advice: string | null;
			failure?: unknown;
		}[],
	) {
		super("operations-acquisition-refused");
	}
}
