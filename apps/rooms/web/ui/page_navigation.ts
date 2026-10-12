// Browser presentation gestures. Session commands go through the Rust controller.
import * as store from "./store.ts";
import { actLocator } from "./page_bootstrap.ts";
import type { RoomsPageContext } from "./page.ts";
import type { DirId, MemberRef } from "./types.ts";
import type { Reach } from "./intent.ts";
import type { RoomsSessionController } from "./controller/session.ts";
import { notificationsBlocked, notificationsUnsupported } from "../../lib/text/attached.ts";
export { dirAddress, directoryId } from "./page_bootstrap.ts";
export { addFiles } from "./composer/files.ts";

/** Pick a room a cold address names, once there is a nickname to enter it
 * with. The session owner handles the selection. Answers false when there is
 * not, and files nothing: the caller says where the reader landed instead, and
 * the card's own route reads that address and files the act. One route files
 * acts, so an address and the card under it cannot say two different things. */
export function showRoom(
	page: RoomsPageContext,
	session: RoomsSessionController,
	dir: DirId,
	name: string,
): boolean {
	const existing = store.existingRoom(page.projection, dir, name);
	if (existing == null && store.requestedDirNick(page.projection, dir) === "") return false;
	session.pickRoom(dir, name, existing?.key);
	return true;
}

export function reachFor(page: RoomsPageContext, act: Reach): void {
	page.managedSession?.openings.dismiss();
	// The card is all that opens. On a phone a press steps back from the list
	// screen to the conversation column the card fills; on a wide layout the
	// rail is a column beside it and closing it would take the rooms away at the
	// moment the reader most wants to see which ones they have.
	store.showJoinFor(page.projection, { ...act, locator: act.locator && actLocator(page, act.locator) });
}

export function aboutDirectory(page: RoomsPageContext, dir: DirId | null, askingLeave = false): void {
	store.showAboutDir(page.projection, dir, askingLeave);
}

export function showDirectory(page: RoomsPageContext, dir: DirId): void {
	const projection = page.projection;
	if (!projection.get().dirs.has(dir)) return;
	page.managedSession?.openings.dismiss();
	const conv = store.ensureDirectory(projection, dir);
	store.switchTo(projection, conv.key);
	store.showAboutDir(projection, null);
	store.closeAboutConv(projection);
	store.showAboutMember(projection, null);
	store.closeSettings(projection);
}

export function aboutMember(page: RoomsPageContext, about: MemberRef | null): void {
	store.showAboutMember(page.projection, about);
}

export async function toggleNotify(page: RoomsPageContext): Promise<string | null> {
	const { notifyOn } = page.projection.get();
	if (notifyOn) {
		store.setNotify(page.projection, false);
		return null;
	}
	if (!("Notification" in globalThis)) {
		return notificationsUnsupported;
	}
	let permitted = Notification.permission;
	if (permitted === "default") permitted = await Notification.requestPermission();
	if (permitted !== "granted") {
		return notificationsBlocked;
	}
	store.setNotify(page.projection, true);
	return null;
}
