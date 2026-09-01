// One-time transfer of a browser workspace into a new durable Rooms session.

import * as z from "zod/mini";
import type { RoomsSessionState } from "../rooms_state.ts";

export const RoomsSessionWorkspaceAdoptionSchema = z.enum(["available", "closed"]);
export type RoomsSessionWorkspaceAdoption = z.infer<typeof RoomsSessionWorkspaceAdoptionSchema>;

export function acceptInitialWorkspace(
	adoption: RoomsSessionWorkspaceAdoption,
	checkpoint: RoomsSessionState,
): RoomsSessionState {
	if (adoption !== "available") throw new Error("this Rooms session has already accepted its initial workspace");
	return checkpoint;
}
