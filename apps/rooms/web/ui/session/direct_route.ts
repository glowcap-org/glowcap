// The path an open direct line takes is a fact of the live session its route
// is exported on, so the page asks Rust for it at use time rather than
// carrying it in the checkpoint, where it would outlive the connection.
import { conversationById } from "./managed/conversation_lookup.ts";
import type { DmConv } from "../conversation.ts";
import type { ManagedRoomsSession } from "./managed/session.ts";
import { coordinate } from "./managed/model.ts";

/** The transport an open direct line runs over, or null while the session
 * holds no installed route for it, the line is closed, or this view may not
 * observe the workspace. */
export async function directRoute(session: ManagedRoomsSession, conv: DmConv): Promise<string | null> {
	const row = conversationById(session.current, conv.persistId);
	if (row?.kind !== "direct" || row.access == null || row.closed || !session.permits("observeWorkspace")) return null;
	return await session.workspace.directRoute(coordinate("directAccess", row.access));
}
