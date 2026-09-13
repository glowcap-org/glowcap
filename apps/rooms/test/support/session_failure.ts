// Test-peer session failures that are ordinary peer departure.

import { CLOSED, IO } from "@glowcap/abi";
import { GlowcapError } from "@glowcap/runtime";

/** A remote peer hanging up, including an abrupt terminal Ctrl-C, is the
 * ordinary end of an accepted connection. Protocol, application, and other I/O
 * failures remain diagnostics. */
export function routinePeerDisconnect(error: unknown): boolean {
	return error instanceof GlowcapError &&
		(error.code === CLOSED || (error.code === IO && error.detail?.endsWith("ConnectionLost") === true));
}
