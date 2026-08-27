// Atomic controller changes for one browser Rooms workspace.

import type { RoomsSessionSnapshot } from "../../../lib/rooms_session.ts";
import type { RoomsControllerSelection, RoomsSessionState } from "../../../lib/rooms_state.ts";
import { attachedSessionFailureText } from "./attached_failure.ts";

export interface VerifiedRoomsSession {
	readonly current: RoomsSessionSnapshot | null;
	adoptWorkspace(checkpoint: RoomsSessionState): Promise<RoomsSessionSnapshot>;
	close(): Promise<void>;
}

export interface RoomsControllerTransition {
	current(): RoomsControllerSelection;
	localCheckpoint(): RoomsSessionState;
	connect(sturdyref: string): Promise<VerifiedRoomsSession>;
	select(controller: RoomsControllerSelection): boolean;
	reportCleanupFailure(error: unknown): void;
}

/** Verify the target authority and commit the browser selection while the
 * temporary connection is live. The connection is always retired before this
 * promise settles, so a caller may reload without racing a second CapTP pair. */
export async function attachRoomsController(
	sturdyref: string,
	transition: RoomsControllerTransition,
): Promise<string> {
	const normalized = sturdyref.trim();
	const current = transition.current();
	if (current.kind === "attached" && current.sturdyref === normalized) return "";
	let attached: VerifiedRoomsSession | null = null;
	let adoptedLocalWorkspace = false;
	try {
		attached = await transition.connect(normalized);
		const snapshot = attached.current;
		if (snapshot == null) throw new Error("the shared session produced no checkpoint");
		if (snapshot.workspaceAdoption === "available") {
			await attached.adoptWorkspace(transition.localCheckpoint());
			adoptedLocalWorkspace = true;
		}
		if (!transition.select({ kind: "attached", sturdyref: normalized })) {
			return adoptedLocalWorkspace
				? "The shared session adopted this workspace, but this browser refused to remember the session capability. Retry the same capability to finish attaching."
				: "This browser refused to save the shared session capability.";
		}
		return "";
	} catch (error) {
		return attachedSessionFailureText(error);
	} finally {
		if (attached != null) {
			try {
				await attached.close();
			} catch (error) {
				transition.reportCleanupFailure(error);
			}
		}
	}
}
