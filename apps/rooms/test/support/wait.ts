// Waiting, with a sentence for when the thing waited on never happens.
//
// A test that awaits a condition plainly turns a broken feature into a hang:
// the run sits until something outside kills it and reports nothing about what
// was missing. Every wait here is bounded and names what it waited for, so the
// same failure becomes a sentence instead.

/** Let `ms` pass. Reach for `until` or `within` first: a sleep standing in for
 * a condition is correct only while the thing it waits for stays faster. */
export const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** Let everything already queued run: one turn of the event loop, so a store
 * that applies an act on the next tick has applied it. No amount of time a
 * test should depend on passes here. */
export const settled = (): Promise<void> => delay(0);

/** Poll `ready` until it holds, or fail after `ms` naming `what`. */
export async function until(ready: () => boolean, what: string, ms = 30_000): Promise<void> {
	const deadline = Date.now() + ms;
	while (!ready()) {
		if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
		await delay(50);
	}
}

/** Wait for one thing with a deadline on it. */
export async function within<T>(work: Promise<T>, what: string, ms = 10_000): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const expiry = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
	});
	try {
		return await Promise.race([work, expiry]);
	} finally {
		clearTimeout(timer);
	}
}
