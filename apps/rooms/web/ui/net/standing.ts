// Saying where this reader stands, and telling the rooms that need to hear it.
//
// The store owns the three levels — the reader's own word, a directory's, a
// room's — and which of them answers for any given room. This owns the telling,
// which is a different question: a room hears its own answer, so setting one
// level moves every room that was taking its answer from that level and leaves
// the rest alone. Saying one word everywhere would otherwise reach every room a
// reader is in, including the ones that had a word of their own.

import * as store from "../store.ts";
import { convSession } from "./live.ts";
import { reason } from "./common.ts";
import { NOT_ROOM_MEMBER, roomErrorOf } from "../../../lib/errors.ts";
import { roomCalled } from "../text.ts";
import type { RoomsPageContext } from "../page.ts";
import type { DirId } from "../types.ts";
/** Tell one room where this reader stands, when that has changed for it.
 *
 * What it was last told is `Live.standingTold`, so a room hears a standing when
 * it changes and not otherwise: saying one word everywhere would otherwise
 * reach every room a reader is in, including the ones with a word of their own
 * that are not affected at all. */
export function tellStanding(page: RoomsPageContext, key: string): void {
	const session = convSession(page, key);
	const room = session?.rooms.get(key);
	if (session === null || room === undefined) return;
	const standing = store.standingFor(page.projection, key);
	if (session.standingTold.get(key) === standing) return;
	session.standingTold.set(key, standing);
	// The room tells everybody, this tab included, so nothing is shown from here:
	// what a roster says is the room's word rather than this tab's intention.
	room.away(standing).catch((error) => {
		// Presence is a courtesy, not a delivery. A room without the verb has no
		// presence concept (the bridge vocabulary is the room's own), and a
		// membership that has ended has no presence left to set — a bridge whose
		// connection dropped, a room this reader was removed from. Neither is the
		// reader's doing, so neither is surfaced. Told stays recorded, so a
		// reconnect does not re-ask a settled question. The ended membership is
		// the typed refusal its throwers mint; only the missing verb, which has
		// no code, is still read from the wording.
		if (reason(error).includes("has no method") || roomErrorOf(error)?.code === NOT_ROOM_MEMBER) return;
		session.standingTold.delete(key);
		// In the room it failed for, named: `tellStandingEverywhere` runs this
		// once per room, and several bare "Could not say that" lines landing in
		// whatever conversation was open said nothing anyone could act on.
		const named = store.getConv(page.projection, key);
		store.deliver(
			page.projection,
			key,
			store.sysItem(
				page.projection,
				`Could not tell ${named?.type === "room" ? roomCalled(named.id, named.held) : "this room"} ` +
					`where you are: ${reason(error)}`,
			),
		);
	});
}

/** Tell every room this reader is in, or every room on one directory. */
function tellStandingEverywhere(page: RoomsPageContext, onDir?: DirId): void {
	for (const conv of page.projection.get().convs.values()) {
		if (conv.type !== "room") continue;
		if (onDir !== undefined && conv.dir !== onDir) continue;
		tellStanding(page, conv.key);
	}
}

/** Say where this reader stands everywhere. */
export function setStanding(page: RoomsPageContext, standing: string): void {
	store.setStanding(page.projection, standing);
	tellStandingEverywhere(page);
}

/** Say where they stand on one directory, or null to follow their own. */
export function setDirStanding(page: RoomsPageContext, dir: DirId, standing: string | null): void {
	store.setDirStanding(page.projection, dir, standing);
	tellStandingEverywhere(page, dir);
}

/** Say where they stand in one room, or null to follow its directory. */
export function setRoomStanding(page: RoomsPageContext, key: string, standing: string | null): void {
	store.setRoomStanding(page.projection, key, standing);
	tellStanding(page, key);
}
