// The assertions the binding's tests share. The binding ships with no
// dependencies, so its tests carry their own vocabulary, and one copy of it
// beats one per file: a message shape or an equality rule changes here once.

/** A harness process fails loudly: say why on stderr, then exit. A `Deno.test`
 * throws instead, so its `finally` still runs. */
export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

export function assert(value: unknown, message = "assertion failed"): asserts value {
	if (!value) throw new Error(message);
}

/** Strict equality, for primitives and identity. When both sides print the
 * same, the message names their types, because they differ in type or
 * identity. */
export function assertEquals(actual: unknown, expected: unknown): void {
	if (actual === expected) return;
	const want = String(expected);
	const got = String(actual);
	throw new Error(
		want === got
			? `expected ${want} (${kindOf(expected)}), got ${got} (${kindOf(actual)})`
			: `expected ${want}, got ${got}`,
	);
}

function kindOf(value: unknown): string {
	return value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
}

/** Structural equality by JSON form, for arrays and plain objects. */
export function assertDeepEquals(actual: unknown, expected: unknown): void {
	if (JSON.stringify(actual) !== JSON.stringify(expected)) {
		throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
	}
}

/** Run `fn` and return what it rejected with; fail if it settled. With
 * `includes`, the rejection must also carry that text. */
export async function assertRejects(fn: () => Promise<unknown>, includes?: string): Promise<unknown> {
	try {
		await fn();
	} catch (error) {
		if (includes !== undefined && !String(error).includes(includes)) {
			throw new Error(`expected rejection containing ${JSON.stringify(includes)}, got ${String(error)}`);
		}
		return error;
	}
	throw new Error(
		includes === undefined
			? "expected the promise to reject"
			: `expected rejection containing ${JSON.stringify(includes)}`,
	);
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
