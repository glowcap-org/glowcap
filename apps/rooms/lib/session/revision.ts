// The revision a session answered a write with.
//
// Its own leaf because both the client and the modules split out of it check
// the same answer the same way, and a second copy is a second thing to get
// wrong about what a valid revision is.

/** The revision a revision-returning verb gave, checked. */
export function sessionRevision(raw: unknown, operation: string): number {
	if (typeof raw !== "bigint" || raw < 0n || raw > BigInt(Number.MAX_SAFE_INTEGER)) {
		throw new Error(`the Rooms session answered an invalid ${operation} revision`);
	}
	return Number(raw);
}
