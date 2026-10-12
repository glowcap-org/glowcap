// Reading a rooms failure out of whatever carried it.
//
// The taxonomy is `error_codes.ts`, which imports nothing. This module is the
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

/** Whether `code` is a status no version of this defines.
 *
 * Calling a shared library built from a different revision than the source that
 * declares its signatures looks like this from up here: the call returns
 * whatever happened to be in the register, and the binding reads it as a status.
 * Every glowcap status is a small negative integer, so a positive one, or one
 * far below the range, is not a status at all. It is also a different number
 * on each attempt, which is the other half of the tell.
 *
 * Worth deciding and not printing, because the number alone sends whoever
 * reads it looking at the transport, the network, and their own configuration,
 * none of which is the problem. The floor is well below the codes in use, so
 * this stays true as more are defined. */
export function impossibleStatus(code: unknown): boolean {
	return typeof code === "number" && Number.isFinite(code) && (code > 0 || code < -64);
}
