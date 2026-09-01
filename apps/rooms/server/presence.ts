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
import { MEMBERSHIP_ENDED, NOTIFY, ROOM_AUTHORITY_CHANGED, ROOM_POLICY_CHANGED } from "../lib/protocol.ts";
import type { RoomServerContext } from "./context.ts";
import { findBySession, type Member, type RoomState } from "./registry.ts";
import { dropIntroductions, dropSignalExchange } from "./introductions.ts";
import { notifyLocalRoom, notifyPublicRoom } from "./discovery.ts";
import { dropWatchers } from "./watchers.ts";
import { retireInvitationsFrom } from "./invitation.ts";

/** Push `from: text` to every subscriber of `state` by calling the inbox
 * capability it gave us. `tell` is the fire-and-forget eventual-send: a notify
 * wants no reply, so it costs one deliver with no answer round-trip. A failed
 * notify is diagnostic only: a member is retired by the session lifecycle hook,
 * never by a failed tell used as a liveness probe (see the catch below). */
export function broadcast(
	ctx: RoomServerContext,
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
			ctx.journal.note(`a presence notify to ${m.nick} failed`, e);
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
	ctx: RoomServerContext,
	state: RoomState,
	nick: string,
	on: boolean,
	exceptSession: Session,
): void {
	for (const m of [...state.members]) {
		if (m.session === exceptSession) continue;
		m.session.tell(m.inbox, NOTIFY, ["room", "", "typing", nick, on]).catch((error) => {
			ctx.journal.note(`a typing notify to ${m.nick} failed`, error);
		});
	}
}

/** The nick this connection is in a room under, or null when it is in none.
 * One authority for what the room server calls a connection: a membership is
 * a presence, and presence is the fact a timeline viewer wants. A DM
 * registration is a directory entry rather than a presence, and naming a
 * connection by one would keep calling a member present after it left. */
function membershipNick(ctx: RoomServerContext, session: Session): string | null {
	for (const state of ctx.live.rooms.values()) {
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
export function statePresence(ctx: RoomServerContext, session: Session): void {
	annotateSession(session, { label: membershipNick(ctx, session) });
}

export function notifyRoomAuthorityChanged(
	ctx: RoomServerContext,
	name: string,
	kind: "manager" | "steward" | "room",
	token: string,
): void {
	const key = name.toLowerCase();
	for (const state of ctx.live.rooms.values()) {
		const durable = state.key.toLowerCase();
		if (durable !== key) continue;
		for (const member of state.members) {
			member.session.tell(member.inbox, NOTIFY, [
				"room",
				"",
				ROOM_AUTHORITY_CHANGED,
				kind,
				token,
				false,
			])
				.catch(
					(error) => ctx.journal.note(`notifying ${member.nick} of room authority rotation failed`, error),
				);
		}
	}
}

export function notifyRoomPolicyChanged(ctx: RoomServerContext, state: RoomState): void {
	for (const member of state.members) {
		member.session.tell(member.inbox, NOTIFY, [
			"room",
			"",
			ROOM_POLICY_CHANGED,
			state.policy.visibility,
			state.policy.entry,
			state.policy.speaking,
		]).catch((error) => ctx.journal.note(`notifying ${member.nick} of room policy failed`, error));
	}
}

/** Remove `session`'s membership from one room, announcing its departure, and
 * delete the room if that emptied it. The `silent` path is for resubscribe,
 * which drops the prior membership and immediately adds a new one, so it must
 * neither announce a spurious leave nor garbage-collect a room it is about to
 * reuse. */
export function leaveRoom(
	ctx: RoomServerContext,
	state: RoomState,
	session: Session,
	options: { silent?: boolean; preserveLines?: boolean; ended?: string } = {},
): boolean {
	const member = state.members.find((candidate) => candidate.session === session);
	return member === undefined ? false : leaveMember(ctx, state, member, options);
}

/** End the exact membership capability, regardless of which session currently
 * holds or calls a delegated occurrence. */
export function leaveMember(
	ctx: RoomServerContext,
	state: RoomState,
	member: Member,
	options: { silent?: boolean; preserveLines?: boolean; ended?: string } = {},
): boolean {
	const { silent = false, preserveLines = false, ended } = options;
	const at = state.members.indexOf(member);
	if (at < 0) return false;
	// A silent leave is the same connection re-claiming its place, so its
	// uploads are still that member's; only a real departure drops them.
	//
	// What this membership let into the room goes on the same cut, and for the
	// same reason. An invitation carries its minter's say-so, so a membership
	// that is over stops vouching for anybody: a kicked member's outstanding
	// invitations do not go on admitting people after them.
	if (!silent) {
		ctx.files.dropMemberUploads(state, member);
		retireInvitationsFrom(ctx.journal, state, member.session);
	}
	if (ended != null) {
		member.session.tell(member.inbox, NOTIFY, ["room", ended, MEMBERSHIP_ENDED]).catch((error) => {
			ctx.journal.note(`ending ${member.nick}'s room membership failed`, error);
		});
	}
	state.members.splice(at, 1);
	ctx.journal.release(member.session, member.inbox, "room member inbox");
	if (member.topic !== null) ctx.journal.release(member.session, member.topic, "room topic authority");
	if (member.seat !== null) ctx.journal.release(member.session, member.seat, "room membership");
	if (!preserveLines) {
		for (const line of member.lines) ctx.journal.release(line.session, line.ref, "room line authority");
		member.lines.length = 0;
	}
	if (!silent) {
		broadcast(ctx, state, "room", `${member.nick} left (${state.members.length} here)`, "leave", member.nick);
	}
	if (!silent && state.members.length === 0) {
		ctx.files.dropRoomFiles(state);
		ctx.live.forgetRoom(state);
	}
	// A real departure also changes what this connection IS: the member is
	// gone but the connection stays, which is exactly the moment the room
	// stops knowing it by that name.
	if (!silent) statePresence(ctx, member.session);
	ctx.operator.noteChange();
	// A real departure changes the live room list: the room closed if it emptied,
	// else its count dropped. A silent resubscribe leaves the count unchanged.
	if (!silent) {
		if (state.members.length === 0) notifyLocalRoom(ctx, state, "closed", 0);
		else notifyLocalRoom(ctx, state, "count", state.members.length);
	}
	return true;
}

// Transport events arrive in loop-drain batches. Retire every connection from
// such a batch before announcing any departure, so one member's leave cannot
// be sent to a sibling whose native session is already condemned but whose
// lifecycle callback was next in the same batch.
export class RoomDisconnects {
	readonly #sessions = new Set<Session>();
	#flushQueued = false;

	constructor(readonly ctx: RoomServerContext) {}

	schedule(session: Session): void {
		this.#sessions.add(session);
		if (this.#flushQueued) return;
		this.#flushQueued = true;
		queueMicrotask(() => this.#flush());
	}

	#flush(): void {
		this.#flushQueued = false;
		const departing = new Set(this.#sessions);
		this.#sessions.clear();
		if (departing.size === 0) return;

		const { live, watchers } = this.ctx;
		for (const state of [...live.rooms.values()]) {
			const removed = state.members.filter((member) => departing.has(member.session));
			if (removed.length !== 0) {
				this.ctx.operator.noteChange();
				// A dropped connection ends its memberships as surely as leaving
				// does, and this path does not go through `leaveMember`, so it
				// says the same two things itself.
				for (const session of new Set(removed.map((member) => member.session))) {
					this.ctx.files.dropUploads(state, session);
					retireInvitationsFrom(this.ctx.journal, state, session);
				}
				state.members = state.members.filter((member) => !departing.has(member.session));

				// Presence mutation is now complete for the whole batch. Only live
				// survivors receive leave records; no failed tell is used as liveness
				// authority.
				for (const member of removed) {
					this.ctx.journal.release(member.session, member.inbox, "disconnected room member inbox");
					if (member.topic !== null) {
						this.ctx.journal.release(member.session, member.topic, "disconnected room topic authority");
					}
					if (member.seat !== null) {
						this.ctx.journal.release(member.session, member.seat, "disconnected room membership");
					}
					for (const line of member.lines) {
						this.ctx.journal.release(line.session, line.ref, "disconnected room line authority");
					}
					member.lines.length = 0;
					broadcast(
						this.ctx,
						state,
						"room",
						`${member.nick} left (${state.members.length} here)`,
						"leave",
						member.nick,
					);
				}

				if (state.members.length === 0) {
					this.ctx.files.dropRoomFiles(state);
					live.forgetRoom(state);
					notifyLocalRoom(this.ctx, state, "closed", 0);
				} else {
					notifyLocalRoom(this.ctx, state, "count", state.members.length);
				}
			} else if (state.members.length === 0 && departing.has(state.lifetimeOwner)) {
				this.ctx.files.dropRoomFiles(state);
				live.forgetRoom(state);
			}
		}

		for (const session of departing) {
			for (const entry of live.forgetForeignRoomsFrom(session)) notifyPublicRoom(this.ctx, entry, "closed", null);
			dropWatchers(watchers, session);
			dropIntroductions(this.ctx, session);
			// The exchanges this session originated die with it: its reply
			// capability is gone, so there is nobody to reject and nothing to say.
			for (const [id, exchange] of [...live.signalExchanges]) {
				if (exchange.originator === session) dropSignalExchange(live, id);
			}
		}
		// A disconnect may have landed while this flush ran.
		if (this.#sessions.size !== 0 && !this.#flushQueued) {
			this.#flushQueued = true;
			queueMicrotask(() => this.#flush());
		}
	}
}
