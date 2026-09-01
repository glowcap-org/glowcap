// What this tab may do: a browser holding its own session — locally or as the
// host — is always admin, and an attached one may do whatever the grant behind
// its link currently carries — including nothing at all, while that grant is
// suspended.

import type { RoomsSessionAccess } from "../../../lib/session/client.ts";
import type { RoomsControllerSelection } from "../../../lib/rooms_state.ts";

/** Resolve the authority the established controller grants this view. */
export function effectiveRoomsSessionAccess(
	controller: Exclude<RoomsControllerSelection, { kind: "none" }>,
	attachedAccess: RoomsSessionAccess | null,
): RoomsSessionAccess;
export function effectiveRoomsSessionAccess(
	controller: RoomsControllerSelection,
	attachedAccess: RoomsSessionAccess | null,
): RoomsSessionAccess | null;
export function effectiveRoomsSessionAccess(
	controller: RoomsControllerSelection,
	attachedAccess: RoomsSessionAccess | null,
): RoomsSessionAccess | null {
	if (controller.kind === "none") return null;
	return controller.kind === "attached" ? attachedAccess ?? "observe" : "admin";
}
