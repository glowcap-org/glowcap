// Delete this browser's Rooms data without changing which page is showing.

import { setHistoryKept } from "../history.ts";
import { clearWorkspaceState } from "../workspace/bundle.ts";
import type { RoomsPageContext } from "../page.ts";

/** Delete every Rooms datum owned by this browser, without navigating. */
export async function deleteRoomsBrowserData(page: RoomsPageContext): Promise<string> {
	try {
		await setHistoryKept(page, false);
		await page.archiveDb.drop();
		return clearWorkspaceState(page) ? "" : "This browser refused to clear the saved Rooms state.";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}
