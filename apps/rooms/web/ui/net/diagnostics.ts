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

import { snapshotDiagnostics, takeDiagnostics } from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import { dirs } from "./live.ts";
import { opsLost, reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import { type HeldDirectoryCapability, releaseHeldCapability } from "./held_capability.ts";

/** The inspect capability this tab fetched, while it still holds it.
 *
 * The swiss number is the capability. Fetching it on this directory's session is how
 * it is taken; the rows in the store are only what it last said. A reconnect
 * drops the reference because it lived on the session. */
let inspectHeld: HeldDirectoryCapability | null = null;

/** Session teardown's drop: return the import while its session is available;
 * the remembered swiss survives so reconnect can take it again. */
export function dropInspect(): void {
	const held = inspectHeld;
	inspectHeld = null;
	store.setDiagnostics(null);
	releaseHeldCapability(held, "diagnostics capability release failed");
}

/** The reader's drop, from the Capabilities toggle: the capability goes and so
 * does its remembered swiss — no path may drop the cap but keep the secret
 * the reader asked to give up. */
export function dropDiagnosticCap(updateVault = true): void {
	const dir = inspectHeld?.dir;
	if (updateVault && dir != null && !forgetOpsSwiss("diagnostics", dir)) {
		store.noteTrouble("capability storage", "the saved diagnostics capability could not be removed");
		return;
	}
	dropInspect();
}

/** Fetch the inspect capability on this directory's session and remember it.
 *
 * Returns an empty string when the tab now holds it, or the reason it would not
 * take. */
export async function takeDiagnosticCap(pasted: string, remember = false): Promise<string> {
	const home = store.get().homeDir;
	const live = home === null ? null : dirs.get(home) ?? null;
	if (home === null || live === null) return "This directory is not connected yet.";
	try {
		const taken = await takeDiagnostics(live.dir.session, pasted);
		// The checkbox is the reader's current word on remembering, so an
		// unchecked take erases an earlier memory rather than leaving it to
		// auto-redeem against their answer.
		const stored = remember ? rememberOpsSwiss("diagnostics", home, pasted) : forgetOpsSwiss("diagnostics", home);
		if (!stored) {
			releaseHeldCapability(
				{ session: live.dir.session, cap: taken.cap, dir: home },
				"unsaved diagnostics capability release failed",
			);
			return "This browser refused to update the saved diagnostics capability.";
		}
		const previous = inspectHeld;
		inspectHeld = { session: live.dir.session, cap: taken.cap, dir: home };
		releaseHeldCapability(previous, "replaced diagnostics capability release failed");
		store.setDiagnostics(taken.rows);
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
export async function refreshDiagnostics(): Promise<void> {
	const held = inspectHeld;
	if (held === null) return;
	try {
		const rows = await snapshotDiagnostics(held.session, held.cap);
		if (inspectHeld !== held) return;
		store.setDiagnostics(rows);
	} catch (error) {
		if (inspectHeld !== held) return;
		dropInspect();
		opsLost("diagnostics", reason(error));
	}
}
