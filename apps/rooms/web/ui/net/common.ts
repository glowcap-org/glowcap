// The small shared answers the data layer's modules all need, kept below them
// so none has to reach sideways for one.
//
// Each is one piece of behaviour with more than one caller, which is the whole
// reason they are here rather than repeated: a reader turning an unknown thrown
// value into a sentence, and a send changing the state its own bubble draws
// from. Anything larger belongs to the seam that owns it.

import * as store from "../store.ts";
import { OPS_CATALOG } from "../ops/catalog.ts";
import type { OpsCap, SendState } from "../types.ts";
import { convSession, type Live } from "./live.ts";

/** What a thrown value says, for a reader.
 *
 * Every failure this layer reports crosses a redeem, a dial, or a carrier of
 * its own, and each of those can throw something that is not an `Error`. One
 * answer, so a caught value never reaches a person as `[object Object]`. */
export function reason(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

/** Say that an operations capability has stopped answering, and why.
 *
 * A capability ends three ways. The reader drops it from its toggle, which
 * needs no notice because they just pressed it; the session it was fetched on
 * reconnects, which is expected and takes a remembered swiss again by itself;
 * or the thing it names refuses. Only the third is news, and it arrives while
 * the reader may be looking at the pane it draws, so it is said out loud
 * rather than left to the toggle falling off on its own. */
/** File a failure that has no reader-facing surface of its own: the console
 * keeps the full object for whoever is debugging with a stack in hand, and
 * the page's trouble journal keeps the sentence an operator can actually
 * find. Never the only copy of a failure a reader must act on — that is a
 * toast's or the conversation's job, with this beside it. */
export function trouble(source: string, err: unknown): void {
	console.error(`rooms: ${source}:`, err);
	store.noteTrouble(source, reason(err));
}

export function opsLost(cap: OpsCap, why: string): void {
	store.toast("failure", `${OPS_CATALOG[cap].pane}: this tab no longer holds that capability. ${why}`);
}

/** Mark how far one of our own messages has got, which is what its bubble
 * draws from. */
export function markSend(key: string, id: number, sendState: SendState | undefined): void {
	store.updateItem(key, id, { state: sendState });
}

/** Said wherever this tab holds a room's conversation but no membership on the
 * live session behind it. Both ways back are named because which one applies
 * turns on something the reader cannot see: a connection part way back re-enters
 * every room it holds a moment later, while a re-entry that was refused waits for
 * them to ask for it. Without this the send looks like a broken control. */
export const NOT_IN_THIS_ROOM =
	"Not in this room at the moment. It is re-entered when the connection returns, or press it in the room list to go back in now.";

/** A room line that cannot be confirmed: drop it from the echo queue and tint it failed. */
export function failRoomSend(key: string, id: number, session: Live | null = convSession(key)): void {
	if (session === null) {
		// No session is no echo queue, and so nothing this line could be waiting
		// on: mark it. Returning here instead left a retry pressed while the
		// directory was away drawn as still going, for good — the optimistic tint
		// says the room has it, and nothing was ever coming to say otherwise.
		markSend(key, id, "failed");
		return;
	}
	const at = session.echoes.findIndex((row) => row.id === id);
	// Already off the queue means the room echoed this line back and
	// `confirmRoomEcho` cleared it. A `say` that rejects afterwards is reporting
	// on a line the room demonstrably received, so tinting it failed here would
	// contradict the echo the user can see.
	if (at < 0) return;
	const [row] = session.echoes.splice(at, 1);
	markSend(row.key, row.id, "failed");
}
