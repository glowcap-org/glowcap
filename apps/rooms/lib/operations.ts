// Taking an operations capability: the shared half of inspect and listeners.
//
// An operations capability is a second object the server publishes under an
// unguessable name, so holding that name is the whole of the authority. The
// operator pastes the name; fetching it on the live directory session is how
// the capability is taken, and letting the reference go is how it is given up.
// What each capability answers differs; how one is taken does not, so that
// flow lives here once.

import type { Ref, Session } from "@pancake/runtime";
import { parseSturdyRef, retainCleanupFailures } from "@pancake/runtime";
import { CAPTP_VERSION } from "./protocol.ts";

/** The bootstrap swiss inside a pasted operations capability.
 *
 * The operator is handed a swiss (the Host publication name) or a sturdyref
 * URI that carries that swiss. Fetching it on the directory session is what
 * taking the capability is. */
export function pastedSwiss(pasted: string): string {
	const trimmed = pasted.trim();
	if (trimmed.includes("://")) {
		try {
			return new TextDecoder().decode(parseSturdyRef(trimmed, CAPTP_VERSION).swissnum);
		} catch {
			return trimmed;
		}
	}
	return trimmed;
}

/** Fetch an operations capability and take its first answer through `first`.
 * A failure after the fetch releases the capability rather than stranding it. */
export async function takeOperationsCap<T>(
	session: Session,
	pasted: string,
	first: (cap: Ref) => Promise<T>,
): Promise<{ cap: Ref; taken: T }> {
	const swiss = pastedSwiss(pasted);
	if (swiss === "") throw new Error("paste the swiss number the server printed");
	const cap = await session.fetch(swiss);
	try {
		return { cap, taken: await first(cap) };
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.release(cap)]);
	}
}
