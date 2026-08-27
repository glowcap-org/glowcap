// Who is here, who just left, and how a room says so.
//
// Presence is the room's own word rather than anything a member asserts: a
// membership is granted by subscribing and ends with the connection or a
// leave, and everything below states that word to the people who need it —
// the room's members, and the watchers following the live list.
//
// Disconnects arrive one connection at a time but are answered in a batch, so a
// server losing many at once says each thing once rather than storming every
// remaining member with a separate line per departure.

import { annotateSession, type Session } from "@pancake/runtime";
import type { Argument } from "@pancake/runtime";
import { NOTIFY } from "../lib/protocol.ts";
import {
	findBySession,
	forgetForeignRoomsFrom,
	forgetRoom,
	handBack,
	rooms,
	type RoomState,
	signalExchanges,
} from "./registry.ts";
import { dropRoomFiles, dropUploads } from "./files.ts";
import { dropIntroductions, dropSignalExchange } from "./introductions.ts";
import { notifyLocalRoom, notifyPublicRoom } from "./discovery.ts";
import { dropWatchers } from "./watchers.ts";
import { noteTrouble } from "./journal.ts";
import { noteOperatorChange } from "./operator/revision.ts";

/** Push `from: text` to every subscriber of `state` by calling the inbox
 * capability it gave us. `tell` is the fire-and-forget eventual-send: a notify
 * wants no reply, so it costs one deliver with no answer round-trip. A failed
 * notify is diagnostic only: a member is retired by the session lifecycle hook,
 * never by a failed tell used as a liveness probe (see the catch below). */
export function broadcast(
	state: RoomState,
	from: string,
	text: string,
	...trailing: Argument[]
): void {
	// Structured trailing args ride after the display text: a presence line
	// carries a join/leave kind and the nick, an attachment post its validated
	// `file` record. A plain chat line passes none. An attachment's blob
	// reference is homed on the poster's connection, so relaying it here trips
	// the transparent gifter: each member gets a give, never a room-proxied
	// byte.
	for (const m of [...state.members]) {
		m.session.tell(m.inbox, NOTIFY, [from, text, ...trailing]).catch((e) => {
			// Membership retirement is owned by the session lifecycle hook below.
			// A failed notify is therefore always diagnostic; it is never used as
			// an opportunistic liveness probe or as authority to mutate presence.
			noteTrouble(`a presence notify to ${m.nick} failed`, e);
		});
	}
}

/** Push an ephemeral typing flag to every *other* member of `state`. Typing is
 * best-effort presence, not a line: it carries no text, is never stored, and is
 * never echoed to the typer (`exceptSession`). It rides the same `notify` inbox as
 * a room line, tagged `"typing"` at the third argument so any subscriber that
 * does not care skips it. A failed tell is ignored — retirement is the session
 * lifecycle hook's, never a failed notify's. */
export function broadcastTyping(
	state: RoomState,
	nick: string,
	on: boolean,
	exceptSession: Session,
): void {
	for (const m of [...state.members]) {
		if (m.session === exceptSession) continue;
		m.session.tell(m.inbox, NOTIFY, ["room", "", "typing", nick, on]).catch((error) => {
			noteTrouble(`a typing notify to ${m.nick} failed`, error);
		});
	}
}

/** The nick this connection is in a room under, or null when it is in none.
 * One authority for what the room server calls a connection: a membership is
 * a presence, and presence is the fact a timeline viewer wants. A DM
 * registration is a directory entry rather than a presence, and naming a
 * connection by one would keep calling a member present after it left. */
function membershipNick(session: Session): string | null {
	for (const state of rooms.values()) {
		const member = findBySession(state, session);
		if (member !== null) return member.nick;
	}
	return null;
}

/** State this connection's room presence on the live trace, or withdraw the
 * claim when it holds none. A claim, not identity — the viewer only displays
 * it — and stating it here means a member joining, changing rooms, or leaving
 * is one visible change in the picture rather than a name frozen at whatever
 * was said first. */
export function statePresence(session: Session): void {
	annotateSession(session, { label: membershipNick(session) });
}

/** Remove `session`'s membership from one room, announcing its departure, and
 * delete the room if that emptied it. The `silent` path is for resubscribe,
 * which drops the prior membership and immediately adds a new one, so it must
 * neither announce a spurious leave nor garbage-collect a room it is about to
 * reuse. */
export function leaveRoom(
	state: RoomState,
	session: Session,
	silent = false,
	preserveLines = false,
): boolean {
	let removed = false;
	// A silent leave is the same connection re-claiming its place, so its
	// uploads are still that member's; only a real departure drops them.
	if (!silent) dropUploads(state, session);
	for (let i = state.members.length - 1; i >= 0; i -= 1) {
		if (state.members[i].session === session) {
			const member = state.members[i];
			state.members.splice(i, 1);
			removed = true;
			// Every membership is answered with a topic capability of its own, so
			// this record's is finished either way: a resubscribe is about to mint
			// another, and a departure ends the membership that held it.
			handBack(session, member.inbox, "room member inbox");
			handBack(session, member.topic, "room topic authority");
			if (!preserveLines) {
				// Leaving gives back the authority over what was said here. The
				// connection may stay, and a membership moving to another connection
				// cannot transfer local occurrences from the old one.
				for (const line of member.lines) handBack(session, line, "room line authority");
				member.lines.length = 0;
			}
			if (!silent) {
				broadcast(
					state,
					"room",
					`${member.nick} left (${state.members.length} here)`,
					"leave",
					member.nick,
				);
			}
		}
	}
	if (!silent && removed && state.members.length === 0) {
		dropRoomFiles(state);
		forgetRoom(state);
	}
	// A real departure also changes what this connection IS: the member is
	// gone but the connection stays, which is exactly the moment the room
	// stops knowing it by that name.
	if (!silent && removed) statePresence(session);
	if (removed) noteOperatorChange();
	// A real departure changes the live room list: the room closed if it emptied,
	// else its count dropped. A silent resubscribe leaves the count unchanged.
	if (!silent && removed) {
		if (state.members.length === 0) notifyLocalRoom(state, "closed", 0);
		else notifyLocalRoom(state, "count", state.members.length);
	}
	return removed;
}

// Transport events arrive in loop-drain batches. Retire every connection from
// such a batch before announcing any departure, so one member's leave cannot
// be sent to a sibling whose native session is already condemned but whose
// lifecycle callback was next in the same batch.
const disconnectedSessions = new Set<Session>();

let disconnectFlushQueued = false;

export function scheduleDisconnect(session: Session): void {
	disconnectedSessions.add(session);
	if (disconnectFlushQueued) return;
	disconnectFlushQueued = true;
	queueMicrotask(flushDisconnects);
}

function flushDisconnects(): void {
	disconnectFlushQueued = false;
	const departing = new Set(disconnectedSessions);
	disconnectedSessions.clear();
	if (departing.size === 0) return;

	for (const state of [...rooms.values()]) {
		const removed = state.members.filter((member) => departing.has(member.session));
		if (removed.length !== 0) {
			noteOperatorChange();
			for (const session of new Set(removed.map((member) => member.session))) dropUploads(state, session);
			state.members = state.members.filter((member) => !departing.has(member.session));

			// Presence mutation is now complete for the whole batch. Only live
			// survivors receive leave records; no failed tell is used as liveness
			// authority.
			for (const member of removed) {
				handBack(member.session, member.inbox, "disconnected room member inbox");
				handBack(member.session, member.topic, "disconnected room topic authority");
				for (const line of member.lines) {
					handBack(member.session, line, "disconnected room line authority");
				}
				member.lines.length = 0;
				broadcast(
					state,
					"room",
					`${member.nick} left (${state.members.length} here)`,
					"leave",
					member.nick,
				);
			}

			if (state.members.length === 0) {
				dropRoomFiles(state);
				forgetRoom(state);
				notifyLocalRoom(state, "closed", 0);
			} else {
				notifyLocalRoom(state, "count", state.members.length);
			}
		} else if (state.members.length === 0 && departing.has(state.creator)) {
			dropRoomFiles(state);
			forgetRoom(state);
		}
	}

	for (const session of departing) {
		for (const entry of forgetForeignRoomsFrom(session)) notifyPublicRoom(entry, "closed", null);
		dropWatchers(session);
		dropIntroductions(session);
		// The exchanges this session originated die with it: its reply
		// capability is gone, so there is nobody to reject and nothing to say.
		for (const [id, exchange] of [...signalExchanges]) {
			if (exchange.originator === session) dropSignalExchange(id);
		}
	}
	// A disconnect may have landed while this flush ran.
	if (disconnectedSessions.size !== 0 && !disconnectFlushQueued) {
		disconnectFlushQueued = true;
		queueMicrotask(flushDisconnects);
	}
}
