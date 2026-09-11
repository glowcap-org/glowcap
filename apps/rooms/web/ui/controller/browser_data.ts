// Delete this browser's Rooms data without changing which page is showing.

import { applicationModule } from "../application.ts";
import { clearWorkspaceState } from "../workspace/bundle.ts";
import type { RoomsPageContext } from "../page.ts";

/** Delete every Rooms datum owned by this browser, without navigating. */
export async function deleteRoomsBrowserData(page: RoomsPageContext): Promise<string> {
	try {
		const controller = page.attachedSession.current;
		if (controller != null) await controller.eraseBrowserArchive();
		else {
			page.browserArchive ??= new (applicationModule().RoomsBrowserArchive)();
			await page.browserArchive.erase();
		}
		return clearWorkspaceState(page)
			? ""
			: "Browser history was erased, but this browser refused to clear the saved Rooms workspace. Retry Delete browser data.";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}
