import type { Ref, Session } from "@pancake/runtime";

/** Give an asynchronous close an error owner when the caller cannot await it. */
export function observeCloseFailure(close: () => Promise<void>, report: (error: unknown) => void): void {
	let result: Promise<void>;
	try {
		result = close();
	} catch (error) {
		report(error);
		return;
	}
	void result.catch(report);
}

/** A refused callback capability still crossed the seam and must be released. */
export function releaseRefusedCapability(
	session: Pick<Session, "release">,
	ref: Ref,
	report: (error: unknown) => void,
): void {
	try {
		session.release(ref);
	} catch (error) {
		report(error);
	}
}

/** Settle every named shutdown operation, reporting failures without dropping
 * the operation that owns each result. */
export function observeSettledFailures(
	operations: readonly { operation: string; promise: Promise<unknown> }[],
	report: (operation: string, error: unknown) => void,
): Promise<void> {
	return Promise.allSettled(operations.map(({ promise }) => promise)).then((results) => {
		for (let i = 0; i < results.length; i += 1) {
			const result = results[i];
			if (result.status === "rejected") report(operations[i].operation, result.reason);
		}
	});
}
