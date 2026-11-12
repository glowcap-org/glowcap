import { projectedError } from "../../../../lib/error_codes.ts";

/** An application result carries its own classification beside its diagnostic.
 * Callers choose this adapter only after proving the outcome's commit state. */
export class ReportedFailure extends Error {
	constructor(reason: string, readonly failure: unknown) {
		super(reason, { cause: failure });
		Object.assign(this, projectedError(failure, reason));
	}
}
