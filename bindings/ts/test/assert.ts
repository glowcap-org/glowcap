// The assertions the binding's tests share. The binding ships with no
// dependencies, so its tests carry their own vocabulary, and one copy of it
// beats one per file: a message shape or an equality rule changes here once.

export function assert(value: unknown, message = "assertion failed"): asserts value {
	if (!value) throw new Error(message);
}

/** Strict equality, for primitives and identity. */
export function assertEquals(actual: unknown, expected: unknown): void {
	if (actual !== expected) {
		throw new Error(`expected ${String(expected)}, got ${String(actual)}`);
	}
}

/** Structural equality by JSON form, for arrays and plain objects. */
export function assertDeepEquals(actual: unknown, expected: unknown): void {
	if (JSON.stringify(actual) !== JSON.stringify(expected)) {
		throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
	}
}

/** Run `fn` and return what it rejected with; fail if it settled. */
export async function assertRejects(fn: () => Promise<unknown>): Promise<unknown> {
	try {
		await fn();
	} catch (error) {
		return error;
	}
	throw new Error("expected the promise to reject");
}

/** `fn` must throw synchronously with a message containing `includes`. */
export function rejects(fn: () => unknown, includes: string): void {
	try {
		fn();
	} catch (error) {
		assert(String(error).includes(includes), `expected ${String(error)} to include ${includes}`);
		return;
	}
	throw new Error(`expected refusal containing ${includes}`);
}

/** A promise and the hand that settles it. */
export function deferred(): { promise: Promise<void>; resolve: () => void } {
	let resolve!: () => void;
	const promise = new Promise<void>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}
