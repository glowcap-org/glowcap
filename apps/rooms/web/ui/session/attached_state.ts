// State import/export for one browser attached to a durable Rooms session.

import type { RoomsSessionController } from "../controller/session.ts";
import * as store from "../store.ts";
import type { AttachedRoomsController } from "./attached.ts";
import {
	encodeWorkspaceState,
	importWorkspaceState,
	parseWorkspaceState,
	workspaceControllerSelection,
	workspaceStateOf,
} from "../workspace_state.ts";
import { emptyRoomsSessionState } from "../../../lib/rooms_state.ts";

type AttachedStateActions = Pick<
	RoomsSessionController,
	"exportRoomsState" | "importRoomsState" | "clearRoomsState"
>;

/** Keep the browser-facing state envelope attached to one session checkpoint.
 * The session owns shared intent; the browser still owns view preferences. */
export function attachedStateActions(
	controller: AttachedRoomsController,
): AttachedStateActions {
	const exportRoomsState = (includeCapabilities = false): string => {
		const snapshot = controller.current;
		if (snapshot == null) throw new Error("The shared session has not supplied its checkpoint yet.");
		const local = workspaceStateOf(store.get());
		const document = {
			...local,
			controller: workspaceControllerSelection(),
			session: snapshot.checkpoint,
		};
		return encodeWorkspaceState(document, includeCapabilities);
	};
	const replaceAttachedState = async (
		document: ReturnType<typeof parseWorkspaceState>,
	): Promise<string> => {
		if (document == null) return "That file is not a complete Rooms state bundle.";
		const attached = workspaceControllerSelection();
		if (attached.kind !== "attached") return "This browser is no longer attached to a shared Rooms session.";
		try {
			const snapshot = await controller.replaceCheckpoint(document.session);
			const installed = JSON.stringify({ ...document, controller: attached, session: snapshot.checkpoint });
			const why = importWorkspaceState(installed, attached);
			if (why !== "") return `The shared session changed, but ${why[0].toLowerCase()}${why.slice(1)}`;
			location.reload();
			return "";
		} catch (error) {
			return error instanceof Error ? error.message : String(error);
		}
	};
	return {
		exportRoomsState,
		importRoomsState: (raw) => replaceAttachedState(parseWorkspaceState(raw)),
		clearRoomsState: () =>
			replaceAttachedState({
				...workspaceStateOf(store.get()),
				session: emptyRoomsSessionState(),
			}),
	};
}
