// The two assertions the rooms tests share: a condition that must hold, and a
// value that must match.
//
// Each was declared file by file, and copies stay in step right up until they
// do not, when two tests report the same failure two ways. One declaration
// here, and `zig build source-check` refuses a test that declares its own.
//
// Comparison is by JSON rather than identity so most callers can assert a
// shape whole. For the strings and booleans the rest compare, it is the same
// answer.

/** Fail with `message` unless `condition` holds. */
export function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

/** Fail unless `actual` matches `expected`.
 *
 * `what` names the assertion in the message. Worth passing wherever a test
 * makes several: "expected 3, got 4" alone leaves a reader counting lines. */
export function assertEquals(actual: unknown, expected: unknown, what?: string): void {
	const a = JSON.stringify(actual);
	const b = JSON.stringify(expected);
	if (a === b) return;
	throw new Error(`${what === undefined ? "" : what + ": "}expected ${b}, got ${a}`);
}
