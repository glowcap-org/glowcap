// Recipes come from the session selected custody under ShareCustody admission.
// Presentation tokens identify local fields. They are never publication names.
import type { RoomConv } from "../types.ts";
import type { ManagedRoomsSession } from "./managed/session.ts";
import { coordinate } from "./managed/model.ts";

/** The three bearer strings a room row can stand for. */
export type RoomBearerKind = "link" | "manager" | "steward";

/** The bearer string behind one of a room's authority tokens, or null while
 * the session holds none or has no snapshot yet.  status-allow: pending state or quoted runtime label */
export async function roomBearer(
	session: ManagedRoomsSession,
	conv: RoomConv,
	kind: RoomBearerKind,
): Promise<string | null> {
	const row = session.current?.intent.conversations.find((row) => row.id === conv.persistId);
	if (row?.kind !== "room" || !session.permits("shareCustody")) return null;
	const key = kind === "link" ? row.access : kind === "manager" ? row.control : row.moderator;
	if (key == null) return null;
	return await session.workspace.custodyRecipe(coordinate(kind === "manager" ? "roomControl" : "roomAccess", key));
}

/** The link a lasting archive share was offered as, or null while the
 * session has no such share or the offer is a live one with no link. */
export async function archiveShareBearer(session: ManagedRoomsSession, id: string): Promise<string | null> {
	const share = session.current?.intent.archiveShares?.find((row) => row.id === id);
	if (share == null || !session.permits("shareCustody")) return null;
	return await session.workspace.custodyRecipe(coordinate("archiveAccess", share.access));
}
