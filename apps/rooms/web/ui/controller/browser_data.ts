// Deleting this browser's Rooms data, from a document that holds none of it.
//
// A running page may own storage it cannot release: a startup whose cleanup
// was refused keeps its workspace open, and IndexedDB will not delete a
// database while a connection to it stays open. So the press only marks the
// tab and reloads, and boot erases before anything opens storage. Deletion
// then never depends on the owner it is replacing closing cleanly.
import { applicationModule } from "../application.ts";
import { THEME_KEY } from "../view_preferences.ts";
import { reloadPage } from "../page_base.ts";
import { localArea, type PageStorage, sessionArea } from "../page_storage.ts";
import { type LocalRefusal, refusalText } from "../../../lib/text/failure.ts";

/** Marked in sessionStorage so only the tab that asked finishes the deletion. */
const PENDING = "rooms.delete-browser-data";
/** Written and removed again once a deletion is complete, so every other tab
 * on this origin hears it through the `storage` event and reloads. */
const DELETED = "rooms.deleted";
/** Every key the Rooms page writes to this origin's storage begins with this,
 * apart from the theme, which the website shares under its own key. */
export const ROOMS_PREFIX = "rooms.";

/** Mark this tab to delete on its next load. Null once marked, and otherwise
 * the browser's refusal, with nothing marked. */
export function requestBrowserDataDeletion(): LocalRefusal | null {
	return sessionArea.write(PENDING, "yes");
}

/** Remove every Rooms key from `storage`, and the shared theme. The Settings
 * card is where the reader chose the theme, so deleting the page's data
 * returns the theme to the page's default too. Null once all are gone, and
 * otherwise the first refusal, with every key it could reach removed. */
export function forgetBrowserPreferences(storage: PageStorage): LocalRefusal | null {
	const keys = storage.keys().filter((key) => key.startsWith(ROOMS_PREFIX));
	let refused: LocalRefusal | null = null;
	for (const key of [...keys, THEME_KEY]) {
		const failed = storage.remove(key);
		refused ??= failed;
	}
	return refused;
}

/** Whether a storage change another tab made announces a finished deletion.
 * A removed preference key would not do, because a browser on the defaults
 * has none to remove, so the deleting tab writes one key for this. */
export function isDeletionNotice(event: { key: string | null; newValue: string | null }): boolean {
	return event.key === DELETED && event.newValue != null;
}

/** Tell every other tab on this origin that the deletion is complete. The key
 * is removed again at once, so nothing stays behind. */
function announceDeletion(storage: PageStorage): LocalRefusal | null {
	return storage.write(DELETED, String(Date.now())) ?? storage.remove(DELETED);
}

/** Reload this tab when another tab deletes the browser's Rooms data. An open
 * tab would otherwise keep writing its own preferences back and keep its
 * closed database's state on screen. The listener lives as long as the page. */
export function reloadWhenAnotherTabDeletes(): void {
	addEventListener("storage", (event) => {
		if (isDeletionNotice(event)) reloadPage();
	});
}

/** Finish a deletion this tab asked for before reloading: every saved
 * session and its messages in IndexedDB, then every Rooms preference and the
 * theme in localStorage. The result is null when no deletion was asked for,
 * an empty string when everything is gone, and otherwise the refusal to
 * show. */
export async function finishBrowserDataDeletion(): Promise<string | null> {
	if (sessionArea.read(PENDING) !== "yes") return null;
	// A mark that stays would erase again on every load.
	const unmarked = sessionArea.remove(PENDING);
	if (unmarked != null) return refusalText(unmarked);
	const deletion = new (applicationModule().RoomsBrowserData)();
	try {
		await deletion.erase();
	} catch (error) {
		return refusalText(error);
	} finally {
		deletion.free();
	}
	const kept = forgetBrowserPreferences(localArea);
	if (kept != null) return refusalText(kept);
	// Everything is gone. This screen and every other tab follow.
	delete document.documentElement.dataset.theme;
	const unheard = announceDeletion(localArea);
	return unheard == null ? "" : refusalText(unheard);
}
