// Reading a rooms failure out of what this binding throws.
//
// The portable taxonomy — the codes and `RoomError` itself — lives in
// `lib/errors.ts`, shared by every client language. What varies per binding is
// the carrier: here an awaited send breaks as a `VowBroken` holding the wire's
// reason string, so this is where that reason is unwrapped before the portable
// `RoomError.from` parses the code out of it.

import { VowBroken } from "@pancake/stack";
import { RoomError } from "../../lib/errors.ts";

/** The typed `RoomError` a caught failure carries, or null. Reads the broken-promise
 * reason (a `VowBroken` from an awaited send) or a plain error message, then parses
 * the code out of it. */
export function roomErrorOf(err: unknown): RoomError | null {
	if (err instanceof RoomError) return err;
	const reason = err instanceof VowBroken
		? err.reason
		: err instanceof Error
		? err.message
		: String(err);
	return RoomError.from(reason);
}
