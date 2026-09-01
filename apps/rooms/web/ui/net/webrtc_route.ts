// Which directory a WebRTC dial signals through when no redeem named one.
//
// One fact: the directory a webrtc designator does not name. Share writes it on
// the sturdyref; Attach records it here; the connector reads it. A Host keeps
// one session per peer, so a leftover join of that directory is that inbox.

import type { Directory } from "../../../lib/room/client.ts";
import type { RoomsPageContext } from "../page.ts";
import { directoryId, pageHomeLive, soleLive } from "./bootstrap.ts";
import { attachSignalingDirectory } from "./reachable.ts";

/** The directory used to `signalOffer` when the connector has no redeem route.
 *
 * A leftover Attach membership is first. When Attach has named a directory and
 * this Host already holds that peer in the UI, that session is next. Ordinary
 * DMs then use this page's directory, then the one live UI directory. */
export function webrtcSignalingRoute(page: RoomsPageContext): Directory | null {
	const dedicated = attachSignalingDirectory(page);
	if (dedicated != null) return dedicated;
	const wanted = page.reachable.signalingDirectoryLocator;
	if (wanted != null && wanted !== "") {
		const live = liveSession(page, wanted);
		if (live != null) return live.dir;
	}
	return pageHomeLive(page)?.dir ?? soleLive(page)?.dir ?? null;
}

/** Whether `signalOffer` will admit a registration on the named directory.
 *
 * Omit `directoryLocator` for the no-hint case: a leftover Attach membership or
 * this page's registered home. A leftover join of another directory is not it. */
export function webrtcAttachSignalingReady(page: RoomsPageContext, directoryLocator?: string): boolean {
	if (directoryLocator == null || directoryLocator === "") {
		return attachSignalingDirectory(page) != null || pageHomeLive(page)?.registered === true;
	}
	if (dedicatedMatches(page, directoryLocator)) return true;
	return liveSession(page, directoryLocator)?.registered === true;
}

/** Whether this Host already holds a session to `directoryLocator`.
 *
 * Attach must not `Directory.connect` that peer again. */
export function webrtcAttachSignalingHeld(page: RoomsPageContext, directoryLocator: string): boolean {
	return dedicatedMatches(page, directoryLocator) || liveSession(page, directoryLocator) != null;
}

/** Close a leftover Attach membership that is not `directoryLocator`. */
export function dropMismatchedWebrtcAttachSignaling(page: RoomsPageContext, directoryLocator: string): void {
	if (attachSignalingDirectory(page) == null || dedicatedMatches(page, directoryLocator)) return;
	page.reachable.stopSignalingDirectory();
}

function dedicatedMatches(page: RoomsPageContext, directoryLocator: string): boolean {
	if (attachSignalingDirectory(page) == null) return false;
	const held = page.reachable.signalingDirectoryLocator;
	if (held == null || held === "") return false;
	return sameDirectory(held, directoryLocator);
}

function liveSession(page: RoomsPageContext, directoryLocator: string) {
	const id = directoryId(directoryLocator);
	return id == null ? null : page.live.dirSession(id);
}

function sameDirectory(left: string, right: string): boolean {
	const a = directoryId(left);
	const b = directoryId(right);
	if (a != null && b != null) return a === b;
	return left === right;
}
