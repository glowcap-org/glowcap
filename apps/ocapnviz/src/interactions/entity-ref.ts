/**
 * What a selection can point at (§ 2.1 of `docs/interaction-model.md`), and
 * the string form a `Set` can hold.
 */

/** What a selection can point at.
 *
 * `endpoint` is a session's end that nothing has attributed to a peer. It is
 * selectable because a reader has to be able to ask what that end claims,
 * and it is its own kind because it is not a peer: it has no lane of its own
 * (its session's row governs it), it cannot be deleted on its own, and every
 * walk over peers has to keep missing it. Its id is `sessionId::side`. */
export type EntityKind = "peer" | "endpoint" | "session" | "message";

export type EntityRef = { kind: EntityKind; id: string };

/** Encoded form used as a Set key, JS Sets can't dedupe object
 *  refs by value, so we serialize to `"<kind>:<id>"`. */
export type EntityRefKey = `${EntityKind}:${string}`;

export function entityKey(ref: EntityRef): EntityRefKey {
	return `${ref.kind}:${ref.id}`;
}

export function parseEntityKey(key: EntityRefKey): EntityRef {
	// Kind is one of four literals; the rest of the string is the id
	// (which may itself contain colons in pathological inputs).
	const idx = key.indexOf(":");
	if (idx <= 0) {
		throw new Error(`invalid EntityRefKey: ${key}`);
	}
	const kind = key.slice(0, idx) as EntityKind;
	const id = key.slice(idx + 1);
	return { kind, id };
}
