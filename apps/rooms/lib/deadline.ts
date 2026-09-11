// Waiting for an answer that may never come.
//
// Every request this client makes goes to somebody else's process: a room is
// whatever directory a reader typed, and the peer behind a direct line is
// whoever answered an introduction. A partner that stays connected and simply
// never answers is not an error anything reports — the send is still in flight,
// the session is still open, and the promise is still pending — so a wait
// without a deadline is a wait for the life of the tab.
//
// That is why the failures it causes are so hard to read from the outside: a
// bubble that says it is sending, a file that says it is arriving, a Join that
// says it is joining, none of them wrong and none of them going anywhere.

import { abortable } from "@glowcap/runtime";

/** A partner accepted a request and did not answer it in time. */
export class Unanswered extends Error {
	constructor(what: string) {
		super(what);
		this.name = "Unanswered";
	}
}

/** `answer`, or `Unanswered` once `ms` has passed.
 *
 * The abandoned request stays outstanding on the session, which is the honest
 * cost of a partner that will not answer: there is nothing to cancel it with,
 * and waiting for it instead is what this exists to stop. `Promise.race` reacts
 * to both, so a rejection that arrives afterwards is still handled rather than
 * surfacing as an unhandled one.
 */
export async function answerWithin<T>(answer: Promise<T>, what: string, ms: number): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const late = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Unanswered(what)), ms);
	});
	try {
		return await Promise.race([answer, late]);
	} finally {
		clearTimeout(timer);
	}
}

/** `answerWithin`, with an owner for a successful answer transferred after the
 * caller's deadline. CapTP cannot cancel an accepted send, so timing out ends
 * the wait but not the transfer. Cleanup failures stay visible on the process
 * diagnostic surface: `abandon` runs after this promise has already refused
 * and cannot report them through the original operation. A producer function
 * also receives the deadline signal so cancellable work can stop in place.
 * `cancel` lets the enclosing owner end that work before its own deadline. */
export async function claimWithin<T>(
	answer: Promise<T> | ((signal: AbortSignal) => Promise<T>),
	what: string,
	ms: number,
	abandon: (late: T) => void | Promise<void>,
	cancel?: AbortSignal,
): Promise<T> {
	const deadline = new AbortController();
	const forwardCancel = (): void => deadline.abort(cancel?.reason);
	if (cancel?.aborted) forwardCancel();
	else cancel?.addEventListener("abort", forwardCancel, { once: true });
	const timer = setTimeout(() => deadline.abort(new Unanswered(what)), ms);
	try {
		return await abortable(
			typeof answer === "function" ? answer(deadline.signal) : answer,
			deadline.signal,
			(failure) => {
				// A cancellable producer normally rejects with the exact reason that
				// already ended this claim. Only a different late failure is new.
				if (failure !== deadline.signal.reason) reportAbandonmentFailure(what, failure);
			},
			abandon,
		);
	} finally {
		clearTimeout(timer);
		cancel?.removeEventListener("abort", forwardCancel);
	}
}

function reportAbandonmentFailure(what: string, error: unknown): void {
	console.error(
		`rooms: ${what}: late answer cleanup failed: ${error instanceof Error ? error.message : error}`,
	);
}
