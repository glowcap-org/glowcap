// Retire one local room membership after the room says it no longer exists.

import * as store from "../store.ts";
import { markSend, trouble } from "./common.ts";
import { convSession } from "./live.ts";
import type { RoomsPageContext } from "../page.ts";
import type { Room } from "../../../lib/room/client.ts";
/** Demote exactly the membership `room` still owns. A replacement that has
 * already taken the same conversation key wins and is left untouched. */
export function retireRoomMembership(page: RoomsPageContext, key: string, room: Room, message: string): boolean {
	const owner = convSession(page, key);
	if (owner?.rooms.get(key) !== room) return false;
	owner.rooms.delete(key);
	owner.standingTold.delete(key);
	owner.refiling.delete(key);
	store.retireRoomLineIds(page.projection, key);

	// The server already ended this membership. Release its client-side
	// occurrences without sending LEAVE, which could target a later replacement
	// on the same connection.
	try {
		room.replaced();
	} catch (error) {
		trouble(page.projection, "ended room membership cleanup failed", error);
	}

	for (let at = owner.echoes.length - 1; at >= 0; at -= 1) {
		const echo = owner.echoes[at];
		if (echo.key !== key) continue;
		owner.echoes.splice(at, 1);
		markSend(page.projection, key, echo.id, "failed");
	}
	const conversation = store.getConv(page.projection, key);
	if (conversation?.type === "room") {
		const lineIds = new Set(store.historyOf(page.projection, key).map((line) => line.id));
		for (const [id, line] of owner.posted) {
			if (!lineIds.has(id)) continue;
			try {
				line.release();
			} catch (error) {
				trouble(page.projection, "ended room line release failed", error);
			}
			owner.posted.delete(id);
		}
	}
	store.setGrants(page.projection, key, new Set());
	store.clearMembers(page.projection, key);
	store.setRoomMembership(page.projection, key, "unavailable", message);
	store.deliver(page.projection, key, store.sysItem(page.projection, message));
	return true;
}
