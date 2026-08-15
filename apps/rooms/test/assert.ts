// The one assertion the rooms unit tests share.
//
// It was six copies, five of them identical to the character and the sixth
// differing only by carrying a label. A helper duplicated per file is the kind
// of thing that stays in step right up until it does not, and then two tests
// report the same failure two ways.
//
// Comparison is by JSON rather than identity so a shape can be asserted whole,
// which is what most of these want; for the strings and booleans the rest
// compare it is the same answer.

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
