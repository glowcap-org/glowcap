// One accepted session's life on this server, for every listener alike.
//
// The boot listener and any listener the admin capability brings up later
// (`listeners.ts`) serve sessions the same way, so the loop lives here rather
// than inside either caller: presence is retired at the transport's terminal
// boundary, and the session shell itself is closed when its serve settles.

import type { Session } from "@pancake/runtime";
import { scheduleDisconnect } from "./presence.ts";
import { noteTrouble } from "./journal.ts";
import { registeredNickOf } from "./introductions.ts";
import { noteOperatorChange } from "./operator/revision.ts";
import { type OperatorRowSource, searchText } from "./operator/page.ts";

const sessions = new Map<string, Session>();
const sessionIds = new Map<Session, string>();

export interface OperatorSessionRow {
	id: string;
	transport: string;
	nick: string;
}

/** Every session but the caller's, as rows a search can scan cheaply. The
 * text is the whole row, because all three of its fields are short and an
 * operator hunting one connection knows any one of them. */
export function* operatorSessionFaces(caller: Session): Iterable<OperatorRowSource<OperatorSessionRow>> {
	for (const [id, session] of sessions) {
		if (session === caller) continue;
		const transport = session.sessionOpen ? session.transportName : "closing";
		const nick = registeredNickOf(session) ?? "";
		yield {
			text: searchText(id, transport, nick),
			build: () => ({ id, transport, nick }),
		};
	}
}

export function sessionByOperatorId(id: string): Session | null {
	return sessions.get(id) ?? null;
}

export function operatorIdForSession(wanted: Session): string | null {
	return sessionIds.get(wanted) ?? null;
}

export function disconnectAllOperatorSessions(caller: Session): void {
	for (const [id, session] of sessions) {
		if (session !== caller) disconnectOperatorSession(id, caller);
	}
}

export function disconnectOperatorSession(id: string, caller: Session): boolean {
	const target = sessions.get(id);
	if (target == null || target === caller) return false;
	// Admission to the disconnect is the inventory transition. Transport close
	// runs next; hiding the row now prevents a second operator action from
	// targeting a session already condemned and lets the mutation answer refresh
	// to the state it just committed.
	sessions.delete(id);
	sessionIds.delete(target);
	noteOperatorChange();
	queueMicrotask(() => void target.close().catch((error) => noteTrouble("operator disconnect failed", error)));
	return true;
}

/** Serve every session `server` accepts until it stops admitting. */
export async function serveAccepted(server: AsyncIterable<Session>): Promise<void> {
	for await (const session of server) {
		const operatorId = crypto.randomUUID();
		sessions.set(operatorId, session);
		sessionIds.set(session, operatorId);
		noteOperatorChange();
		// Presence is indexed by connection, so retire it at the transport's own
		// terminal boundary. Learning this from a later failed notify leaves stale
		// membership between closure and the next broadcast.
		const stopClose = session.onClose(() => scheduleDisconnect(session));
		// When the member's connection ends, the membership cleanup runs and
		// then the session itself is retired. Without the close, the native
		// session shell outlives its dead transport: the host accumulates one
		// shell per departed member, and the live timeline never hears this
		// side of the wire end, so a vanished member's session lingers on the
		// picture until the room server restarts.
		session.serve().catch((error) => {
			noteTrouble("a member session failed", error);
		}).finally(() => {
			if (sessions.delete(operatorId)) {
				sessionIds.delete(session);
				noteOperatorChange();
			}
			try {
				stopClose();
			} catch (error) {
				noteTrouble("a member session close observer would not stop", error);
			}
			scheduleDisconnect(session); // pre-transport serve refusal joins the same cleanup batch
			session.close().catch((error) => {
				noteTrouble("a member session would not retire", error);
			});
		});
	}
}
