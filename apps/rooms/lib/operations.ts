// Taking an operations capability on the directory that printed its name.
//
// An operations capability is a second object the server publishes under an
// unguessable name, so holding that name is the whole of the authority. The
// operator pastes the name; fetching it on the live directory session is how
// the capability is taken, and letting the reference go is how it is given up.
// What each capability answers differs; how one is taken does not, so that
// flow lives here once.

import type { Ref, Session } from "@glowcap/runtime";
import { retainCleanupFailures } from "@glowcap/runtime";
import { parseRoomsSturdyref } from "./locator.ts";

/** The Host publication name printed by this directory.
 *
 * A sturdyref also names a Host. Stripping that locator and fetching its swiss
 * on the current directory can silently retarget authority when two servers
 * restored the same operator state. Operations therefore accepts only the bare
 * swiss explicitly scoped by the live directory in front of the reader. */
export function operationsSwiss(pasted: string): string {
	const trimmed = pasted.trim();
	if (trimmed.includes("://")) {
		throw new Error("paste the bare swiss number this directory printed, not a sturdyref for another host");
	}
	return trimmed;
}

/** A swiss presented to the endpoint named alongside it. Unlike a capability
 * fetched on the current directory, the visualizer has a separately selected
 * endpoint, so accepting its complete sturdyref cannot retarget another Host. */
export function presentedSwiss(pasted: string): string {
	const trimmed = pasted.trim();
	if (!trimmed.includes("://")) return trimmed;
	return new TextDecoder().decode(parseRoomsSturdyref(trimmed).swissnum);
}

/** Fetch an operations capability and take its first answer through `first`.
 * A failure after the fetch releases the capability rather than stranding it. */
export async function takeOperationsCap<T>(
	session: Session,
	pasted: string,
	first: (cap: Ref) => Promise<T>,
): Promise<{ cap: Ref; taken: T }> {
	const swiss = operationsSwiss(pasted);
	if (swiss === "") throw new Error("paste the swiss number the server printed");
	const cap = await session.fetch(swiss);
	try {
		return { cap, taken: await first(cap) };
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.release(cap)]);
	}
}
