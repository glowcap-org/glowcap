// Delete this browser's Rooms data without changing which page is showing.

import { applicationModule } from "../application.ts";
import { clearWorkspaceState } from "../workspace/bundle.ts";
import type { RoomsPageContext } from "../page.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { clearWorkspaceRefused } from "../../../lib/text/attached.ts";

/** Delete every Rooms datum owned by this browser, without navigating. */
export async function deleteRoomsBrowserData(page: RoomsPageContext): Promise<string> {
	try {
		const controller = page.attachedSession.current;
		if (controller != null) await controller.eraseBrowserArchive();
		else {
			page.browserArchive ??= new (applicationModule().RoomsBrowserArchive)();
			await page.browserArchive.erase();
		}
		return clearWorkspaceState(page) ? "" : clearWorkspaceRefused;
	} catch (error) {
		return refusalText(error);
	}
}
