// A public, stable identity for comparing two views of the same room
// authority without disclosing that authority's unguessable swiss number.

const encoder = new TextEncoder();
const DOMAIN = "pancake.rooms.room-authority\u0000";

function hex(bytes: Uint8Array): string {
	return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Derive a non-authority correlator from a room publication's swiss number.
 *
 * A steward may answer this value to prove which room it governs. It must not
 * answer the swiss itself: stewardship does not imply the authority to enter
 * or pass on the room. */
export async function roomAuthorityIdentity(swiss: string): Promise<string> {
	if (swiss === "") throw new Error("a room authority needs a swiss number");
	const digest = await crypto.subtle.digest("SHA-256", encoder.encode(DOMAIN + swiss));
	return hex(new Uint8Array(digest));
}
