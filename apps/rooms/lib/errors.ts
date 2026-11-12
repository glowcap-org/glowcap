// Native Rooms protocol failures carry explicit application provenance.
import { VowBroken } from "@glowcap/runtime";
import { RoomsError, roomsErrorIn } from "./error_codes.ts";

export * from "./error_codes.ts";

/** Read protocol codes only from wire breaks or explicit local Loam refusals. */
export function roomsErrorOf(err: unknown): RoomsError | null {
	if (err instanceof VowBroken) {
		const message = err.applicationMessage();
		return message == null ? null : RoomsError.from(message);
	}
	return roomsErrorIn(err);
}
