// One accepted session's life on this server, for every listener alike.
//
// The boot listener and any listener the admin capability brings up later
// (`listeners.ts`) serve sessions the same way, so the loop lives here rather
// than inside either caller: presence is retired at the transport's terminal
// boundary, and the session shell itself is closed when its serve settles.

import type { Session } from "@glowcap/runtime";
import { routinePeerDisconnect } from "../lib/session_failure.ts";
import type { RoomDisconnects } from "./presence.ts";
import { registeredNickOf } from "./introductions.ts";
import { type OperatorRowSource, searchText } from "./operator/page.ts";

export interface OperatorSessionRow {
	id: string;
	transport: string;
	nick: string;
	/** Whether this row is the caller's own connection. */
	you: boolean;
}

/** One Rooms server's accepted CapTP sessions and their operator identities. */
export class RoomServerSessions {
	readonly #sessions = new Map<string, Session>();
	readonly #ids = new Map<Session, string>();
	readonly #disconnects: RoomDisconnects;

	constructor(disconnects: RoomDisconnects) {
		this.#disconnects = disconnects;
	}

	/** Every live session, the caller's own connection included and marked, as
	 * rows a search can scan cheaply. The caller is listed because the
	 * registrations pane names a holder by session id: hiding the asking
	 * session made the caller's own claim read as held by nothing, which is
	 * exactly what a lifecycle leak would look like. The text is the whole
	 * row, because all three fields are short and an operator hunting one
	 * connection knows any one of them. */
	*operatorFaces(caller: Session): Iterable<OperatorRowSource<OperatorSessionRow>> {
		for (const [id, session] of this.#sessions) {
			const transport = session.sessionOpen ? session.transportName : "closing";
			const nick = registeredNickOf(this.#disconnects.ctx.live, session) ?? "";
			const you = session === caller;
			yield {
				text: searchText(id, transport, nick),
				build: () => ({ id, transport, nick, you }),
			};
		}
	}

	byOperatorId(id: string): Session | null {
		return this.#sessions.get(id) ?? null;
	}

	operatorIdFor(wanted: Session): string | null {
		return this.#ids.get(wanted) ?? null;
	}

	disconnectAll(caller: Session): void {
		for (const [id, session] of this.#sessions) {
			if (session !== caller) this.disconnect(id, caller);
		}
	}

	disconnect(id: string, caller: Session): boolean {
		const target = this.#sessions.get(id);
		if (target == null || target === caller) return false;
		// Admission to the disconnect is the inventory transition. Transport close
		// runs next; hiding the row now prevents a second operator action from
		// targeting a session already condemned and lets the mutation answer refresh
		// to the state it just committed.
		this.#sessions.delete(id);
		this.#ids.delete(target);
		this.#disconnects.ctx.operator.noteChange();
		queueMicrotask(() =>
			void target.close().catch((error) =>
				this.#disconnects.ctx.journal.note("operator disconnect failed", error)
			)
		);
		return true;
	}

	/** Serve every session the listener accepts until it stops admitting. */
	async serve(server: AsyncIterable<Session>): Promise<void> {
		for await (const session of server) {
			const operatorId = crypto.randomUUID();
			this.#sessions.set(operatorId, session);
			this.#ids.set(session, operatorId);
			this.#disconnects.ctx.operator.noteChange();
			// Presence is indexed by connection, so retire it at the transport's own
			// terminal boundary. Learning this from a later failed notify leaves stale
			// membership between closure and the next broadcast.
			const stopClose = session.onClose(() => this.#disconnects.schedule(session));
			// When the member's connection ends, the membership cleanup runs and
			// then the session itself is retired. Without the close, the native
			// session shell outlives its dead transport: the host accumulates one
			// shell per departed member, and the live timeline never hears this
			// side of the wire end, so a vanished member's session lingers on the
			// picture until the room server restarts.
			session.serve().catch((error) => {
				if (!routinePeerDisconnect(error)) this.#disconnects.ctx.journal.note("a member session failed", error);
			}).finally(() => {
				if (this.#sessions.delete(operatorId)) {
					this.#ids.delete(session);
					this.#disconnects.ctx.operator.noteChange();
				}
				try {
					stopClose();
				} catch (error) {
					this.#disconnects.ctx.journal.note("a member session close observer would not stop", error);
				}
				this.#disconnects.schedule(session); // pre-transport serve refusal joins the same cleanup batch
				session.close().catch((error) => {
					this.#disconnects.ctx.journal.note("a member session would not retire", error);
				});
			});
		}
	}
}
