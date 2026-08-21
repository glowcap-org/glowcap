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

import type { Ref, Session } from "@pancake/runtime";
import { snapshotDiagnostics, takeDiagnostics } from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { dirs } from "./live.ts";
import { opsLost, reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";

/** The inspect capability this tab fetched, while it still holds it.
 *
 * The swiss number is the capability. Fetching it on this directory's session is how
 * it is taken; the rows in the store are only what it last said. A reconnect
 * drops the reference because it lived on the session. */
let inspectHeld: { session: Session; cap: Ref; dir: DirId } | null = null;

/** Session teardown's drop: the reference dies with its session, but a
 * remembered swiss survives so the reconnect can take it again. */
export function dropInspect(): void {
	if (inspectHeld === null) return;
	inspectHeld = null;
	store.setDiagnostics(null);
}

/** The reader's drop, from the Advanced toggle: the capability goes and so
 * does its remembered swiss — no path may drop the cap but keep the secret
 * the reader asked to give up. */
export function dropDiagnosticCap(): void {
	const dir = inspectHeld?.dir;
	dropInspect();
	if (dir !== undefined) forgetOpsSwiss("diagnostics", dir);
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
		inspectHeld = { session: live.dir.session, cap: taken.cap, dir: home };
		// The checkbox is the reader's current word on remembering, so an
		// unchecked take erases an earlier memory rather than leaving it to
		// auto-redeem against their answer.
		if (remember) rememberOpsSwiss("diagnostics", home, pasted);
		else forgetOpsSwiss("diagnostics", home);
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
	if (inspectHeld === null) return;
	try {
		store.setDiagnostics(await snapshotDiagnostics(inspectHeld.session, inspectHeld.cap));
	} catch (error) {
		dropInspect();
		opsLost("diagnostics", reason(error));
	}
}
