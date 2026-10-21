// Reading a rooms failure out of whatever carried it.
//
// The taxonomy is `error_codes.ts`, which imports no runtime. This module is the
// runtime half. What varies per binding is the carrier, and here an awaited
// send breaks as a `VowBroken` holding the wire's reason, so this is where that
// reason is unwrapped before the portable `RoomsError.from` parses the code out
// of it. Other client languages mirror the codes and read them through their
// binding's carrier. A browser has no `VowBroken` and reads the message
// directly, which is why the split exists.

import { VowBroken } from "@glowcap/runtime";
import { RoomsError } from "./error_codes.ts";

export * from "./error_codes.ts";

/** The typed `RoomsError` a caught failure carries, or null. Reads the
 * broken-promise reason (a `VowBroken` from an awaited send) or a plain error
 * message, then parses the code out of it. */
export function roomsErrorOf(err: unknown): RoomsError | null {
	if (err instanceof RoomsError) return err;
	const reason = err instanceof VowBroken ? err.reason : err instanceof Error ? err.message : String(err);
	return RoomsError.from(reason);
}
