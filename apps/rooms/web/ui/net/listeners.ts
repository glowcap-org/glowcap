// The operator's hand on this directory's listeners, when a reader holds it.
//
// Like inspect next door in `diagnostics.ts`, the listeners object is a
// capability the tab fetches by swiss number and then holds, and dropping it
// is how the reader gives the hand back. It lives on the session it was
// fetched on, so a reconnect drops it and the reader takes it again if they
// still want it. The rows in the store are only what it last said.

import * as store from "../store.ts";
import { listenerDown, listenerUp, listListeners, takeListeners } from "../../../lib/room/client.ts";
import { roomErrorOf } from "../../../lib/errors.ts";
import type { RoomsPageContext } from "../page.ts";
import { DIRECTORY_NOT_CONNECTED, liveHomeDir, opsLost, reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import { invalidateOperations } from "../ops/invalidation.ts";
import { type HeldDirectoryCapability, releaseHeldCapability } from "./held_capability.ts";

/** The listeners capability one page fetched. */
export class PageListeners {
	held: HeldDirectoryCapability | null = null;
}

/** Session teardown's drop: return the import while its session is available;
 * the remembered swiss survives so reconnect can take it again. */
export function dropListeners(page: RoomsPageContext): void {
	const held = page.listeners.held;
	page.listeners.held = null;
	store.setListeners(page.projection, null);
	releaseHeldCapability(held, "listeners capability release failed");
}

/** The reader's drop, from the Capabilities toggle: the capability goes and so
 * does its remembered swiss — no path may drop the cap but keep the secret
 * the reader asked to give up. */
export function dropListenersCap(page: RoomsPageContext, updateVault = true): void {
	const dir = page.listeners.held?.dir;
	if (updateVault && dir != null && !forgetOpsSwiss(page, "listeners", dir)) {
		store.noteTrouble(page.projection, "capability storage", "the saved listeners capability could not be removed");
		return;
	}
	dropListeners(page);
}

/** What a refused listener verb should read as: the typed sentence when the
 * server said one, the whole message otherwise. */
function refusal(error: unknown): string {
	return roomErrorOf(error)?.detail ?? reason(error);
}

/** Fetch the listeners capability on this directory's session and remember it.
 *
 * Returns an empty string when the tab now holds it, or the reason it would
 * not take. */
export async function takeListenersCap(page: RoomsPageContext, pasted: string, remember = false): Promise<string> {
	const live = liveHomeDir(page);
	if (live === null) return DIRECTORY_NOT_CONNECTED;
	try {
		const taken = await takeListeners(live.dir.session, pasted);
		// The checkbox is the reader's current word on remembering, so an
		// unchecked take erases an earlier memory rather than leaving it to
		// auto-redeem against their answer.
		const stored = remember
			? rememberOpsSwiss(page, "listeners", live.id, pasted)
			: forgetOpsSwiss(page, "listeners", live.id);
		if (!stored) {
			releaseHeldCapability(
				{ session: live.dir.session, cap: taken.cap, dir: live.id },
				"unsaved listeners capability release failed",
			);
			return "This browser refused to update the saved listeners capability.";
		}
		const previous = page.listeners.held;
		page.listeners.held = { session: live.dir.session, cap: taken.cap, dir: live.id };
		releaseHeldCapability(previous, "replaced listeners capability release failed");
		store.setListeners(page.projection, taken.rows);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Ask the listeners capability in hand for the live listeners.
 *
 * A refusal ends the capability rather than leaving a stale seat list on
 * screen under switches that would refuse, and says so; see the same catch in
 * `refreshDiagnostics` next door. */
export async function refreshListeners(page: RoomsPageContext): Promise<void> {
	const held = page.listeners.held;
	if (held === null) return;
	try {
		const rows = await listListeners(held.session, held.cap);
		if (page.listeners.held !== held) return;
		store.setListeners(page.projection, rows);
	} catch (error) {
		if (page.listeners.held !== held) return;
		dropListeners(page);
		opsLost(page.projection, "listeners", reason(error));
	}
}

/** Bring a listener up on `transport`, with values for whichever of the
 * seat's declared knobs the reader filled in. Empty when it came up (the
 * fresh list is already in the store), otherwise the refusal for the pane to
 * show. */
export async function requestListenerUp(
	page: RoomsPageContext,
	transport: string,
	options?: Record<string, string | number>,
): Promise<string> {
	if (page.listeners.held === null) return "This tab no longer holds the listeners capability.";
	try {
		await listenerUp(page.listeners.held.session, page.listeners.held.cap, transport, options);
		await invalidateOperations(page, page.listeners.held.dir);
		return "";
	} catch (error) {
		return refusal(error);
	}
}

/** Take the listener numbered `id` down, the same way. */
export async function requestListenerDown(page: RoomsPageContext, id: number): Promise<string> {
	if (page.listeners.held === null) return "This tab no longer holds the listeners capability.";
	try {
		await listenerDown(page.listeners.held.session, page.listeners.held.cap, id);
		await invalidateOperations(page, page.listeners.held.dir);
		return "";
	} catch (error) {
		return refusal(error);
	}
}
