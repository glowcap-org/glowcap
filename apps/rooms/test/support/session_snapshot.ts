import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";

export function adminSessionView(): Pick<
	RoomsSessionSnapshot,
	"archiveShares" | "directoryViews" | "access" | "workspaceAdoption" | "grants" | "handedRooms"
> {
	return {
		archiveShares: [],
		directoryViews: [],
		access: "admin",
		workspaceAdoption: "closed",
		grants: [],
		handedRooms: [],
	};
}

export function roomsSessionSnapshot(
	overrides: Partial<RoomsSessionSnapshot> = {},
): RoomsSessionSnapshot {
	return {
		revision: 0,
		checkpoint: emptyRoomsSessionState(),
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: [],
		memberLocator: null,
		roomViews: [],
		...adminSessionView(),
		...overrides,
	};
}
