// Waiting, with a sentence for when the thing waited on never happens.
//
// A test that awaits a condition plainly turns a broken feature into a hang:
// the run sits until something outside kills it and reports nothing about what
// was missing. Every wait here is bounded and names what it waited for, so the
// same failure becomes a sentence instead.

/** Let `ms` pass. Reach for `until` or `within` first: a sleep standing in for
 * a condition is correct only while the thing it waits for stays faster. */
export const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** Let every promise that can settle without time settle. Fakes that answer
 * with promises alone finish in one macrotask turn, which runs every microtask
 * they chain. Use `until` for anything a timer or real I/O answers. */
export function settle(): Promise<void> {
	return new Promise<void>((done) => setTimeout(done, 0));
}

/** Poll `ready` until it holds, or fail after `ms` naming `what`. `ready` may
 * look something up, so it may answer late, and the deadline bounds an answer
 * that never comes too. */
export async function until(ready: () => boolean | Promise<boolean>, what: string, ms = 30_000): Promise<void> {
	const deadline = Date.now() + ms;
	while (!(await within(Promise.resolve(ready()), what, Math.max(0, deadline - Date.now())))) {
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
