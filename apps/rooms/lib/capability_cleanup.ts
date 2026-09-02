// Capability cleanup outcomes shared by Rooms runtime owners.

import { CLOSED } from "@glowcap/abi";
import { GlowcapError } from "@glowcap/runtime";

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
