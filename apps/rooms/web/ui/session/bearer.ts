// The bearer strings the page never keeps: a room's entry link, manager, and
// moderator, and the link of a lasting archive share.
//
// The Rust checkpoint holds each one. The store holds only a token that says
// the authority is held and tells it from another, so nothing subscribed to
// the conversation map is handed a secret it does not draw. A control that
// copies or shows the string asks here, at render or press time, and reads it
// straight from the session's current snapshot.

import type { RoomsPageContext } from "../page.ts";
import type { RoomConv } from "../types.ts";

/** The three bearer strings a room row can stand for. */
export type RoomBearerKind = "link" | "manager" | "steward";

/** The bearer string behind one of a room's authority tokens, or null while
 * the session holds none or has no snapshot yet. */
export function roomBearer(page: RoomsPageContext, conv: RoomConv, kind: RoomBearerKind): string | null {
	const checkpoint = page.attachedSession.current?.current?.checkpoint;
	if (checkpoint == null) return null;
	for (const conversation of checkpoint.conversations) {
		if (conversation.kind !== "room" || conversation.id !== conv.persistId) continue;
		return conversation[kind] ?? null;
	}
	return null;
}

/** The link a lasting archive share was offered as, or null while the
 * session has no such share or the offer is a live one with no link. */
export function archiveShareBearer(page: RoomsPageContext, id: string): string | null {
	const shares = page.attachedSession.current?.current?.archiveShares;
	if (shares == null) return null;
	for (const share of shares) {
		if (share.id !== id) continue;
		return share.sturdyref === "" ? null : share.sturdyref;
	}
	return null;
}
