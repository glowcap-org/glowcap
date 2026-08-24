// Saying where this reader stands, and telling the rooms that need to hear it.
//
// The store owns the three levels — the reader's own word, a directory's, a
// room's — and which of them answers for any given room. This owns the telling,
// which is a different question: a room hears its own answer, so setting one
// level moves every room that was taking its answer from that level and leaves
// the rest alone. Saying one word everywhere would otherwise reach every room a
// reader is in, including the ones that had a word of their own.

import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { convSession } from "./live.ts";
import { reason } from "./common.ts";
import { roomCalled } from "../text.ts";

/** Tell one room where this reader stands, when that has changed for it.
 *
 * What it was last told is `Live.standingTold`, so a room hears a standing when
 * it changes and not otherwise: saying one word everywhere would otherwise
 * reach every room a reader is in, including the ones with a word of their own
 * that are not affected at all. */
export function tellStanding(key: string): void {
	const session = convSession(key);
	const room = session?.rooms.get(key);
	if (session === null || room === undefined) return;
	const standing = store.standingFor(key);
	if (session.standingTold.get(key) === standing) return;
	session.standingTold.set(key, standing);
	// The room tells everybody, this tab included, so nothing is shown from here:
	// what a roster says is the room's word rather than this tab's intention.
	room.away(standing).catch((error) => {
		// A room without the verb is a room without the concept — the bridge
		// vocabulary is the room's own — and absence is not something to scold
		// the reader about. Told stays recorded, so a reconnect does not ask a
		// room the same question it already declined to have.
		if (reason(error).includes("has no method")) return;
		session.standingTold.delete(key);
		// In the room it failed for, named: `tellStandingEverywhere` runs this
		// once per room, and several bare "Could not say that" lines landing in
		// whatever conversation was open said nothing anyone could act on.
		const named = store.getConv(key);
		store.deliver(
			key,
			store.sysItem(
				`Could not tell ${named?.type === "room" ? roomCalled(named.id, named.held) : "this room"} ` +
					`where you are: ${reason(error)}`,
			),
		);
	});
}

/** Tell every room this reader is in, or every room on one directory. */
function tellStandingEverywhere(onDir?: DirId): void {
	for (const conv of store.get().convs.values()) {
		if (conv.type !== "room") continue;
		if (onDir !== undefined && conv.dir !== onDir) continue;
		tellStanding(conv.key);
	}
}

/** Say where this reader stands everywhere. */
export function setStanding(standing: string): void {
	store.setStanding(standing);
	tellStandingEverywhere();
}

/** Say where they stand on one directory, or null to follow their own. */
export function setDirStanding(dir: DirId, standing: string | null): void {
	store.setDirStanding(dir, standing);
	tellStandingEverywhere(dir);
}

/** Say where they stand in one room, or null to follow its directory. */
export function setRoomStanding(key: string, standing: string | null): void {
	store.setRoomStanding(key, standing);
	tellStanding(key);
}
