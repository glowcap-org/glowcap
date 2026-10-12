/**
 * Structural equality over the shapes a timeline document is made of.
 *
 * The engine asks "is this the same document?" in three places, a
 * transaction that changed nothing, an undo round trip, and whether
 * the buffer still says what it was built from, and this is the one
 * answer all three read.
 *
 * It is written out rather than reached for as `JSON.stringify(a) ===
 * JSON.stringify(b)`, which is the same question asked in a way that
 * gets it wrong twice. Text equality makes key ORDER part of the
 * answer, so a peer whose pin was removed and re-added at the same
 * coordinates reads as a changed document, and it builds two whole
 * strings to throw away, on a question asked once per frame while the
 * transport runs. This walks and stops at the first difference,
 * allocating nothing.
 *
 * Valid for JSON-shaped values only: numbers, strings, booleans,
 * `null`, arrays, and plain objects. That is exactly what a
 * `TimelineDocument` is, because Zod parses one out of JSON and the
 * schema admits nothing else, no dates, no maps, no class instances.
 * A field whose value could be one of those would need this function
 * to grow a case before it could be compared here.
 *
 * A key carrying `undefined` and a key that is not there count as the
 * same thing, because the document uses both spellings for an absent
 * field: `restoreSnapshotInto` writes `doc.recording = undefined`
 * where a freshly parsed document simply has no `recording`.
 */
export function deepEqual(a: unknown, b: unknown): boolean {
	if (a === b) return true;
	if (
		typeof a !== "object" || typeof b !== "object" ||
		a === null || b === null
	) return false;
	if (Array.isArray(a) || Array.isArray(b)) {
		if (!Array.isArray(a) || !Array.isArray(b)) return false;
		if (a.length !== b.length) return false;
		for (let i = 0; i < a.length; i += 1) {
			if (!deepEqual(a[i], b[i])) return false;
		}
		return true;
	}
	const left = a as Record<string, unknown>;
	const right = b as Record<string, unknown>;
	for (const key of Object.keys(left)) {
		if (!deepEqual(left[key], right[key])) return false;
	}
	// Only the keys the first object did not carry are left to check:
	// the loop above already compared every shared one. A key the first
	// object lacks is equal exactly when the second is not really
	// stating it either.
	for (const key of Object.keys(right)) {
		if (!(key in left) && right[key] !== undefined) return false;
	}
	return true;
}
