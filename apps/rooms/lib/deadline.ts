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
