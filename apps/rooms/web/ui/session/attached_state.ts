// State import/export for one browser attached to a durable Rooms session.

import {
	installWorkspaceStatePersistence,
	parseWorkspaceState,
	workspaceControllerSelection,
	workspaceStateOf,
} from "../workspace_state.ts";
import { encodeWorkspaceState, importWorkspaceState } from "../workspace/bundle.ts";
import { sharedRoomsSession } from "../../../lib/workspace_view.ts";
import { emptyRoomsSessionState } from "../application.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import type { RoomsPageContext } from "../page.ts";
import type { AttachedRoomsController } from "./attached.ts";
import { coverForReload, finishCoveredReload, uncoverReload } from "../boot.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { bundleIncomplete, noLongerInSharedSession, sessionChangedBut } from "../../../lib/text/attached.ts";

export function reloadWouldEndHostedSession(page: RoomsPageContext): boolean {
	return workspaceControllerSelection(page).kind === "hosted";
}

type AttachedStateActions = Pick<
	RoomsSessionController,
	"exportRoomsState" | "importRoomsState" | "clearRoomsState"
>;

/** Keep the browser-facing state envelope attached to one session checkpoint.
 * The session owns shared intent; the browser still owns view preferences. */
export function attachedStateActions(
	page: RoomsPageContext,
	controller: AttachedRoomsController,
): AttachedStateActions {
	const exportRoomsState = (includeCapabilities = false): string => {
		const snapshot = controller.current;
		if (snapshot == null) throw new Error("The shared session has not supplied its checkpoint yet.");
		const local = workspaceStateOf(page, page.projection.get());
		const document = {
			...local,
			controller: workspaceControllerSelection(page),
			session: snapshot.checkpoint,
		};
		return encodeWorkspaceState(document, includeCapabilities);
	};
	const replaceAttachedState = async (
		document: ReturnType<typeof parseWorkspaceState>,
	): Promise<string> => {
		if (document == null) return bundleIncomplete;
		const attached = workspaceControllerSelection(page);
		if (attached.kind !== "local" && sharedRoomsSession(attached) == null) {
			return noLongerInSharedSession;
		}
		const hosting = reloadWouldEndHostedSession(page);
		if (!hosting) coverForReload();
		try {
			const snapshot = await controller.replaceCheckpoint(document.session);
			const installed = JSON.stringify({ ...document, controller: attached, session: snapshot.checkpoint });
			const why = importWorkspaceState(page, installed, attached);
			if (why !== "") {
				if (!hosting) uncoverReload();
				return sessionChangedBut(why);
			}
			if (hosting) installWorkspaceStatePersistence(page);
			else finishCoveredReload();
			return "";
		} catch (error) {
			if (!hosting) uncoverReload();
			return refusalText(error);
		}
	};
	return {
		exportRoomsState,
		importRoomsState: (raw) => replaceAttachedState(parseWorkspaceState(raw)),
		clearRoomsState: () =>
			replaceAttachedState({
				...workspaceStateOf(page, page.projection.get()),
				session: emptyRoomsSessionState(),
			}),
	};
}
