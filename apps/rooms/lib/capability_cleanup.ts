// Capability cleanup outcomes shared by Rooms runtime owners.

import { CLOSED } from "@glowcap/abi";
import { GlowcapError, type Ref, type Session } from "@glowcap/runtime";
import { claimWithin } from "./deadline.ts";

/** A closed CapTP session has already reclaimed every reference it carried.
 * Later release or unwatch calls cannot do more cleanup and are successful for
 * ownership purposes; other failures still need to be surfaced. */
export function cleanupSettledBySessionClose(error: unknown): boolean {
	return error instanceof GlowcapError && error.code === CLOSED;
}

/** Run a release whose final owner is the enclosing session. Session closure
 * is successful cleanup; any other refusal remains visible without masking the
 * operation that caused cleanup to run. */
export function settleCapabilityCleanup(label: string, cleanup: () => void): void {
	try {
		cleanup();
	} catch (error) {
		if (cleanupSettledBySessionClose(error)) return;
		console.error(`rooms: ${label}: ${error instanceof Error ? error.message : error}`);
	}
}

/** Claim a capability answer before its deadline, or return an answer that
 * arrives later to the session that transferred it. */
export function claimCapabilityWithin(
	session: Session,
	answer: Promise<Ref> | ((signal: AbortSignal) => Promise<Ref>),
	what: string,
	ms: number,
): Promise<Ref> {
	return claimWithin(
		answer,
		what,
		ms,
		(late) => settleCapabilityCleanup(`${what}: late capability release failed`, () => session.release(late)),
	);
}
