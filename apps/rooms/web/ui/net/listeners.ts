// The operator's hand on this directory's listeners, when a reader holds it.
//
// Like inspect next door in `diagnostics.ts`, the listeners object is a
// capability the tab fetches by swiss number and then holds, and dropping it
// is how the reader gives the hand back. It lives on the session it was
// fetched on, so a reconnect drops it and the reader takes it again if they
// still want it. The rows in the store are only what it last said.

import type { Ref, Session } from "@pancake/runtime";
import { listenerDown, listenerUp, listListeners, takeListeners } from "../../../lib/room_client.ts";
import { roomErrorOf } from "../../../lib/errors.ts";
import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { dirs } from "./live.ts";
import { reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";

/** The listeners capability this tab fetched, while it still holds it. */
let listenersHeld: { session: Session; cap: Ref; dir: DirId } | null = null;

/** Session teardown's drop: the reference dies with its session, but a
 * remembered swiss survives so the reconnect can take it again. */
export function dropListeners(): void {
	if (listenersHeld === null) return;
	listenersHeld = null;
	store.setListeners(null);
}

/** The reader's drop, from the Advanced toggle: the capability goes and so
 * does its remembered swiss — no path may drop the cap but keep the secret
 * the reader asked to give up. */
export function dropListenersCap(): void {
	const dir = listenersHeld?.dir;
	dropListeners();
	if (dir !== undefined) forgetOpsSwiss("listeners", dir);
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
export async function takeListenersCap(pasted: string, remember = false): Promise<string> {
	const home = store.get().homeDir;
	const live = home === null ? null : dirs.get(home) ?? null;
	if (home === null || live === null) return "This directory is not connected yet.";
	try {
		const taken = await takeListeners(live.dir.session, pasted);
		listenersHeld = { session: live.dir.session, cap: taken.cap, dir: home };
		// The checkbox is the reader's current word on remembering, so an
		// unchecked take erases an earlier memory rather than leaving it to
		// auto-redeem against their answer.
		if (remember) rememberOpsSwiss("listeners", home, pasted);
		else forgetOpsSwiss("listeners", home);
		store.setListeners(taken.rows);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Ask the listeners capability in hand for the live listeners. */
export async function refreshListeners(): Promise<void> {
	if (listenersHeld === null) return;
	try {
		store.setListeners(await listListeners(listenersHeld.session, listenersHeld.cap));
	} catch {
		dropListeners();
	}
}

/** Bring a listener up on `transport`, with values for whichever of the
 * seat's declared knobs the reader filled in. Empty when it came up (the
 * fresh list is already in the store), otherwise the refusal for the pane to
 * show. */
export async function requestListenerUp(
	transport: string,
	options?: Record<string, string | number>,
): Promise<string> {
	if (listenersHeld === null) return "This tab no longer holds the listeners capability.";
	try {
		await listenerUp(listenersHeld.session, listenersHeld.cap, transport, options);
		await refreshListeners();
		return "";
	} catch (error) {
		return refusal(error);
	}
}

/** Take the listener numbered `id` down, the same way. */
export async function requestListenerDown(id: number): Promise<string> {
	if (listenersHeld === null) return "This tab no longer holds the listeners capability.";
	try {
		await listenerDown(listenersHeld.session, listenersHeld.cap, id);
		await refreshListeners();
		return "";
	} catch (error) {
		return refusal(error);
	}
}
