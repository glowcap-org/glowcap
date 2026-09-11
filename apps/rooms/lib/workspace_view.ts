// Read-only discrimination of a projected controller choice. No validation or I/O.
import type { RoomsControllerSelection, SharedRoomsControllerSelection } from "./rooms_state.ts";

/** The shared session this controller names, or null when the workspace is local. */
export function sharedRoomsSession(
	controller: RoomsControllerSelection,
): SharedRoomsControllerSelection | null {
	return controller.kind === "attached" || controller.kind === "hosted" ? controller : null;
}
