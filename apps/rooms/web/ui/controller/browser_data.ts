import { deleteHistoryDatabase } from "../archive_database.ts";
import { setHistoryKept } from "../history.ts";
import { clearWorkspaceState } from "../workspace_state.ts";

/** Delete every Rooms datum owned by this browser, without navigating. */
export async function deleteRoomsBrowserData(): Promise<string> {
	try {
		await setHistoryKept(false);
		await deleteHistoryDatabase();
		return clearWorkspaceState() ? "" : "This browser refused to clear the saved Rooms state.";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}
