import type { RoomsSessionFacet } from "../../../lib/rooms_session.ts";
import type { RoomsControllerSelection } from "../../../lib/rooms_state.ts";

/** Resolve the authority the established controller grants this view. */
export function effectiveRoomsSessionAccess(
	controller: Exclude<RoomsControllerSelection, { kind: "none" }>,
	attachedAccess: RoomsSessionFacet | null,
): RoomsSessionFacet;
export function effectiveRoomsSessionAccess(
	controller: RoomsControllerSelection,
	attachedAccess: RoomsSessionFacet | null,
): RoomsSessionFacet | null;
export function effectiveRoomsSessionAccess(
	controller: RoomsControllerSelection,
	attachedAccess: RoomsSessionFacet | null,
): RoomsSessionFacet | null {
	if (controller.kind === "none") return null;
	return controller.kind === "local" ? "admin" : attachedAccess ?? "observe";
}
