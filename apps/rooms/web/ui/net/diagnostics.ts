// The operator's view of a directory, when a reader has been given one.
//
// Inspect is not a directory method: it is a second capability the room server
// publishes under an unguessable name, and holding that name is the whole of
// the authority. So this is a capability a tab fetches and then holds, and
// dropping it is how a reader gives the view up — the same shape as everything
// else here, applied to looking rather than talking.
//
// It lives on the session it was fetched on, so a reconnect drops it and the
// reader takes it again if they still want it.

import * as store from "../store.ts";
import { snapshotDiagnostics, takeDiagnostics } from "../../../lib/room/client.ts";
import type { RoomsPageContext } from "../page.ts";
import { DIRECTORY_NOT_CONNECTED, liveHomeDir, opsLost, reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import { type HeldDirectoryCapability, releaseHeldCapability } from "./held_capability.ts";

/** The inspect capability one page fetched. */
export class PageInspect {
	held: HeldDirectoryCapability | null = null;
}

/** Session teardown's drop: return the import while its session is available;
 * the remembered swiss survives so reconnect can take it again. */
export function dropInspect(page: RoomsPageContext): void {
	const held = page.inspect.held;
	page.inspect.held = null;
	store.setDiagnostics(page.projection, null);
	releaseHeldCapability(held, "diagnostics capability release failed");
}

/** The reader's drop, from the Capabilities toggle: the capability goes and so
 * does its remembered swiss — no path may drop the cap but keep the secret
 * the reader asked to give up. */
export function dropDiagnosticCap(page: RoomsPageContext, updateVault = true): void {
	const dir = page.inspect.held?.dir;
	if (updateVault && dir != null && !forgetOpsSwiss(page, "diagnostics", dir)) {
		store.noteTrouble(
			page.projection,
			"capability storage",
			"the saved diagnostics capability could not be removed",
		);
		return;
	}
	dropInspect(page);
}

/** Fetch the inspect capability on this directory's session and remember it.
 *
 * Returns an empty string when the tab now holds it, or the reason it would not
 * take. */
export async function takeDiagnosticCap(page: RoomsPageContext, pasted: string, remember = false): Promise<string> {
	const live = liveHomeDir(page);
	if (live === null) return DIRECTORY_NOT_CONNECTED;
	try {
		const taken = await takeDiagnostics(live.dir.session, pasted);
		// The checkbox is the reader's current word on remembering, so an
		// unchecked take erases an earlier memory rather than leaving it to
		// auto-redeem against their answer.
		const stored = remember
			? rememberOpsSwiss(page, "diagnostics", live.id, pasted)
			: forgetOpsSwiss(page, "diagnostics", live.id);
		if (!stored) {
			releaseHeldCapability(
				{ session: live.dir.session, cap: taken.cap, dir: live.id },
				"unsaved diagnostics capability release failed",
			);
			return "This browser refused to update the saved diagnostics capability.";
		}
		const previous = page.inspect.held;
		page.inspect.held = { session: live.dir.session, cap: taken.cap, dir: live.id };
		releaseHeldCapability(previous, "replaced diagnostics capability release failed");
		store.setDiagnostics(page.projection, taken.rows);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Ask the inspect capability in hand for a fresh snapshot.
 *
 * A refusal ends the capability rather than leaving a stale table on screen
 * under a toggle that says it is held, and says so: this is the one way a
 * capability goes that the reader did not ask for and cannot see coming. */
export async function refreshDiagnostics(page: RoomsPageContext): Promise<void> {
	const held = page.inspect.held;
	if (held === null) return;
	try {
		const rows = await snapshotDiagnostics(held.session, held.cap);
		if (page.inspect.held !== held) return;
		store.setDiagnostics(page.projection, rows);
	} catch (error) {
		if (page.inspect.held !== held) return;
		dropInspect(page);
		opsLost(page.projection, "diagnostics", reason(error));
	}
}
