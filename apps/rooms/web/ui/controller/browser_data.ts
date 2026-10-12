// Deleting this browser's Rooms data, from a document that holds none of it.
//
// A running page may own storage it cannot release: a startup whose cleanup
// was refused keeps its workspace open, and IndexedDB will not delete a
// database while a connection to it stays open. So the press only marks the
// tab and reloads, and boot erases before anything opens storage. Deletion
// then never depends on the owner it is replacing closing cleanly.

import { applicationModule } from "../application.ts";

const PENDING = "rooms.delete-browser-data";

/** Mark this tab for deletion. The caller reloads it. */
export function requestBrowserDataDeletion(): void {
	sessionStorage.setItem(PENDING, "yes");
}

/** Erase a deletion this tab asked for before reloading. Answers null when none
 * was asked, "" once erased, or the refusal. The mark clears first, so a
 * refusal is shown once and pressing Delete again is a fresh request. */
export async function finishBrowserDataDeletion(chosenKey: string): Promise<string | null> {
	if (sessionStorage.getItem(PENDING) !== "yes") return null;
	sessionStorage.removeItem(PENDING);
	const deletion = new (applicationModule().RoomsBrowserData)();
	try {
		await deletion.erase();
		localStorage.removeItem(chosenKey);
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	} finally {
		deletion.free();
	}
}
