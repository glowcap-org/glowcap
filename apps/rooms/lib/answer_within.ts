// Bounded promise waits shared by native clients and the browser viewer.

/** A partner accepted a request and did not answer it in time. */
export class Unanswered extends Error {
	constructor(what: string) {
		super(what);
		this.name = "Unanswered";
	}
}

/** Wait at most `ms` without cancelling the underlying work. A late rejection
 * remains observed through the race, even after the deadline ends the wait. */
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
