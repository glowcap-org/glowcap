// A proved conflict or a refusal settles a submitted acquisition or session
// command and frees its request. Only a conflict permits re-preparation, and
// only an outcome nothing settled keeps the request for replay. A kept request
// keeps its sequence, so sending it again, over the same handle or one a new
// link resumed it onto, asks the session how it ended: the session applies it
// at most once.
import { invariant } from "../../../../lib/invariant.ts";
import { ReportedFailure } from "./reported_failure.ts";
import { connectionLost, LocalRefusal, refusalText } from "../../../../lib/text/failure.ts";
import { projectedError } from "../../../../lib/error_codes.ts";
type ConflictKey = "acquisition-conflict" | "access-issue-conflict" | "access-edit-conflict";
type UnknownKey = "acquisition-unknown" | "access-issue-unknown" | "access-edit-unknown" | "access-share-unheld";
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

/** Read the Rust application's outcome. A reported uncertainty throws while
 * the holder keeps the request. One whose link to the session was lost throws
 * that loss, so its holder settles it over the next link. An unrecognized
 * answer violates the shared application contract and cannot authorize
 * another submission. */
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
			if (status === "uncertain" && connectionLost(failure)) throw projectedError(failure, said ?? "");
			if (status === "uncertain") throw submissionError({ status, reason: said ?? undefined });
		}
	}
	invariant(false, reason);
}

/** Submit a prepared acquisition. An outcome Rust could not settle throws, and
 * the holder keeps the request. */
export async function submitAcquisition(request: { submit(): Promise<unknown> }): Promise<SettledOutcome> {
	return settledOutcome(await request.submit(), ["committed", "conflict", "refused"]);
}

/** Only some prepared acquisitions retain their target for re-preparation
 * after a proved conflict. */
function isRepreparable<A extends object>(request: A): request is A & { reprepare(): Promise<A> } {
	return "reprepare" in request;
}

/** Submit a prepared acquisition, and after each proved conflict prepare it
 * again at the newer revision and submit that, up to the bound. Only a proved
 * conflict permits a new revision, and Rust re-preparation keeps the exact
 * acquired target, source, coordinates and recipe. A failed re-preparation
 * leaves the last request held, and uncertainty never enters this path.
 * `held` is told the request held now and whether it may have reached the
 * session: a request on its way may have, and one a conflict refused or not
 * yet submitted has not. `go` says whether to go on. Returns the outcome and
 * the request it settled, which the caller frees. */
export async function submitResolvingConflicts<A extends { submit(): Promise<unknown>; free(): void }>(
	first: A,
	held: (request: A, sent: boolean) => void,
	go: () => boolean,
): Promise<{ outcome: SettledOutcome; request: A }> {
	const submit = async (request: A) => {
		held(request, true);
		const outcome = await submitAcquisition(request);
		if (outcome.status === "conflict") held(request, false);
		return outcome;
	};
	let request = first;
	let outcome = await submit(request);
	for (
		let attempt = 1;
		outcome.status === "conflict" && isRepreparable(request) && go() && attempt < MAX_CONFLICT_REPREPARATIONS;
		attempt++
	) {
		const replacement: A = await request.reprepare();
		held(replacement, false);
		request.free();
		request = replacement;
		if (!go()) break;
		outcome = await submit(request);
	}
	return { outcome, request };
}

/** Submit a prepared session command. An outcome Rust could not settle throws,
 * and the holder keeps the request. */
export async function submitCommand(request: { submit(): Promise<unknown> }): Promise<CommandAdmission> {
	const outcome = settledOutcome(await request.submit(), [
		"conflict",
		"refused",
		"pending",
		"committed",
		"unsent",
		"unknown",
	]);
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

/** What a submit through a held control came to: the outcome the session
 * answered, or null for a submit that threw and may still have landed, with the
 * failure it says, if any, in its holder's words. */
export type SubmitAnswer<T extends SubmissionOutcome> = {
	readonly outcome: T | null;
	readonly failure: Error | null;
	readonly reason: string;
};
/** Submit through `submit`, and say what came of it in the words `keys` name.
 * A local refusal sent nothing and is thrown. Any other throw may have landed,
 * so it answers as nothing settled. */
export async function settleSubmit<T extends SubmissionOutcome>(
	submit: () => Promise<T>,
	keys: SubmissionFailureContext,
): Promise<SubmitAnswer<T>> {
	let outcome: T;
	try {
		outcome = await submit();
	} catch (error) {
		if (error instanceof LocalRefusal) throw error;
		const failure = new LocalRefusal(keys.uncertain, { cause: error });
		return { outcome: null, failure, reason: refusalText(failure) };
	}
	const failure = submissionError(outcome, keys);
	return { outcome, failure, reason: failure == null ? "" : refusalText(failure) };
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
