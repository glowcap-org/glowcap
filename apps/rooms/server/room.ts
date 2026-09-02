// The room object itself: what a member may ask of the room they are in.
//
// One membership per connection, so nothing here takes a "from" argument — the
// capability the call arrives on is the authority to speak in this room. The
// caller is read from the session whose turn is running rather than one closed
// over when the room was made, because a room reference crosses connections: a
// handoff carries it to another member, and a redeem enlivens it from a link.
//
// Everything a member is granted comes back as a reference: the line they just
// posted, the topic, the upload that will carry a file. There are no ranks to
// check because there is nothing to check them against.

import { currentSession, Ref } from "@glowcap/runtime";
import type { Argument, Behavior, Session } from "@glowcap/runtime";
import {
	AWAY,
	CALLED,
	LINK,
	LISTED,
	MANAGED_ROOM_IDENTITY,
	NOTIFY,
	PRIVATE,
	ROOM_POLICY,
	SUBSCRIBE,
	TOPIC,
	UNLISTED,
} from "../lib/protocol.ts";
import { NICK_TAKEN, NICK_TOO_LONG, NO_SUCH_ROOM, ROOM_FULL, RoomError } from "../lib/errors.ts";
import { lineCost, MAX_LINE, MAX_ROOM_MEMBERS, NAME_VOUCHER_BYTES, nickRefusal } from "../lib/limits.ts";
import type { RoomServerContext } from "./context.ts";
import { claimedByAnother, findBySession, nickKey, roomDurableIdentity, type RoomState } from "./registry.ts";
import { roomIsListed } from "../lib/room/policy.ts";
import { topicBehavior } from "./lines.ts";
import { notifyLocalRoom } from "./discovery.ts";
import { broadcast, leaveRoom, statePresence } from "./presence.ts";
import { redeemNameVoucher, registeredByAnother } from "./introductions.ts";
import type { RoomHistory } from "./history.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import type { RoomLinks } from "./room_links.ts";
import type { RoomMembershipKind } from "../lib/room/membership.ts";
import { membershipBehavior } from "./membership.ts";
import type { OneShotRoomAdmission } from "../lib/room/admission.ts";
import { liveRoomInvitationIssuer } from "./invitation.ts";

/** Who is present, said to the one reader who just arrived.
 *
 * A sentence, because it is read rather than parsed: the names travel beside it
 * as a `roster` field, so nothing downstream has to take them back out of this.
 * A lone arrival is told what that means rather than handed a list of one, and
 * is told it about the room rather than about themselves: the client draws this
 * under a mark reading "Only you", and "Only you" over "You are the only one"
 * is the same word twice in two lines.
 *
 * One producer, because this line is written twice over: once here to be sent,
 * and once by `rosterForAdmission` to decide whether it would fit. Two spellings
 * of one sentence would let the room admit a member whose roster line it then
 * could not carry. */
export function rosterSaid(names: readonly string[]): string {
	if (names.length === 1) return "Nobody else is in the room.";
	return names.slice(0, -1).join(", ") + " and " + names[names.length - 1] + " are in the room.";
}

/** The exact roster a successful subscribe will send, before any membership
 * mutation. A same-session re-entry replaces its row and therefore costs no
 * additional seat. */
export function rosterForAdmission(state: RoomState, session: Session, nick: string): string[] {
	const names = state.members.filter((member) => member.session !== session).map((member) => member.nick);
	names.push(nick);
	if (names.length > MAX_ROOM_MEMBERS) {
		throw new RoomError(ROOM_FULL, `a room may hold at most ${MAX_ROOM_MEMBERS} live members`);
	}
	if (lineCost(rosterSaid(names)) > MAX_LINE) {
		throw new RoomError(ROOM_FULL, `another member would make the room roster exceed ${MAX_LINE} bytes`);
	}
	return names;
}

/** The room behavior for one connection. The room grants at most one live
 * membership to the connection, so `post` needs no "from" argument — the
 * capability the post arrives on is the authority to speak in this room. */
export function roomBehavior(
	ctx: RoomServerContext,
	state: RoomState,
	history: RoomHistory,
	links: RoomLinks | null = null,
	options: {
		membershipKind?: RoomMembershipKind;
		active?: () => boolean;
		admission?: OneShotRoomAdmission;
	} = {},
) {
	const membershipKind = options.membershipKind ?? "participant";
	const active = () => (options.active?.() ?? true) && (options.admission?.available() ?? true);
	const invitations = liveRoomInvitationIssuer(
		ctx.live,
		state,
		(claimant, current, kind, admission) =>
			claimant.spawn(roomBehavior(ctx, current, history, links, { membershipKind: kind, admission })),
	);
	// The same return the directory declares: a room answers with a value, and
	// one of its verbs answers with a promise of one, because minting a durable
	// name persists before it publishes.
	//
	// The caller is the session whose turn is running, never a session closed
	// over at spawn time. A room reference crosses connections now — a handoff
	// carries it to another member, and a redeem enlivens it from a link — so
	// the connection that asked for the reference and the connection calling it
	// are two different facts. Closing over the first blamed every call on it:
	// a member taking up a handed room was seated *as the inviter's
	// connection*, which silently replaced the inviter's own membership.
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		const session = currentSession();
		if (session === null) throw new Error("a room is reachable only over a session");
		if (verb !== SUBSCRIBE && hasCapabilityArguments(args)) {
			throwAfterReleasingCapabilities(
				session,
				args,
				new Error(`room ${verb} does not take capability arguments`),
			);
		}
		if (verb === SUBSCRIBE) {
			if (!active()) {
				throwAfterReleasingCapabilities(
					session,
					args,
					new RoomError(NO_SUCH_ROOM, "this room entrance is no longer offered"),
				);
			}
			const nick = typeof args[0] === "string" ? args[0] : "";
			const inbox = args[1];
			const voucher = args[2];
			if (
				(args.length !== 2 && args.length !== 3) || !(inbox instanceof Ref) ||
				(args.length === 3 && (!(voucher instanceof Uint8Array) || voucher.byteLength !== NAME_VOUCHER_BYTES))
			) {
				throwAfterReleasingCapabilities(
					session,
					args,
					new Error(
						`subscribe needs an inbox capability, a name, and optional ${NAME_VOUCHER_BYTES}-byte name voucher`,
					),
				);
			}
			// This is where a room grants a name, and every member carries what it
			// grants: into the roster, into the line saying somebody joined, and in
			// front of everything they say.
			const unnameable = nickRefusal(nick);
			if (unnameable != null) {
				ctx.journal.release(session, inbox, "refused room subscriber inbox");
				throw new RoomError(NICK_TOO_LONG, unnameable);
			}
			// The one step here that can fail — spawning the topic export — is done
			// first, before any of the bookkeeping that a failure after it would
			// leave inconsistent: a spent voucher, an unseated previous member, a
			// dropped count. A refusal past this point hands the export back rather
			// than orphaning it. Everything after the spawn is infallible commit.
			let topic: Ref | null = null;
			const member: import("./registry.ts").Member = {
				nick,
				inbox,
				session,
				lines: findBySession(state, session)?.lines ?? [],
				topic: null,
				seat: null,
				kind: membershipKind,
				away: "",
			};
			try {
				if (membershipKind === "participant") topic = session.spawn(topicBehavior(ctx, state, links));
				member.topic = topic;
				member.seat = session.spawn(membershipBehavior(ctx, state, member, { history, invitations }));
			} catch (error) {
				if (topic !== null) ctx.journal.release(session, topic, "unseated room topic authority");
				ctx.journal.release(session, inbox, "unseated room subscriber inbox");
				throw error;
			}
			const refuse = (error: Error): never => {
				if (member.seat !== null) ctx.journal.release(session, member.seat, "unseated room membership");
				if (topic !== null) ctx.journal.release(session, topic, "unseated room topic authority");
				ctx.journal.release(session, inbox, "unseated room subscriber inbox");
				throw error;
			};
			// Whether this subscribe carries proof that the caller is the name's own
			// holder on another connection: a voucher the name capability minted,
			// redeemed exactly once. Checked only where a holder stands in the way,
			// so an unneeded voucher is not burnt; both refusals below yield to it,
			// because both exist to keep one name on one person and the voucher is
			// the proof this is that person.
			const entitled = () => voucher instanceof Uint8Array && redeemNameVoucher(ctx.live, nick, voucher);
			if (claimedByAnother(state, session, nick)) {
				if (!entitled()) refuse(new RoomError(NICK_TAKEN, `name "${nick}" is already claimed`));
				// The same member, moving connections: the seat they held from the
				// old one is re-claimed rather than doubled, the way a same-session
				// resubscribe already replaces itself.
				const key = nickKey(nick);
				const previous = state.members.find(
					(member) => member.session !== session && nickKey(member.nick) === key,
				);
				if (previous !== undefined) leaveRoom(ctx, state, previous.session, { silent: true });
			} // The room is not the only holder of a name. Someone who left this room
			// but stayed connected still answers to theirs for direct messages, so
			// granting it here would put one name on two people: the roster would
			// show the newcomer while an introduction under that name reached the
			// member who left.
			else if (registeredByAnother(ctx.live, session, nick) && !entitled()) {
				refuse(
					new RoomError(
						NICK_TAKEN,
						`name "${nick}" is held for direct messages by a member who is still connected`,
					),
				);
			}
			// A resubscribe (same connection re-claiming) nets no count change, so it
			// must not fire a discovery event; a fresh membership does.
			const already = findBySession(state, session);
			const wasMember = already !== null;
			const names = (() => {
				try {
					return rosterForAdmission(state, session, nick);
				} catch (error) {
					return refuse(error instanceof Error ? error : new Error(String(error)));
				}
			})();
			options.admission?.consume();
			// The references to this connection's recent lines outlive the record
			// holding them: re-claiming a place is not saying anything, and a
			// member who can no longer fix what they said a moment ago would have
			// been robbed by bookkeeping.
			if (wasMember) leaveRoom(ctx, state, session, { silent: true, preserveLines: true });
			state.members.push(member);
			ctx.operator.noteChange();
			// The one moment this process KNOWS which member a session
			// carries: state it for the trace, so a viewer can name the peer
			// instead of showing its claimed address.
			statePresence(ctx, session);
			// Listed-ness before the join line this arrival also receives.
			// `/join` of a locator seats from that fact; the join broadcast is
			// sent to every member and must not be the first thing the occupant
			// hears, or listed-ness is still unknown and a public link sits in a
			// held clone. Additive: an older client skips the unknown tag.
			// Subscribe still answers the topic capability in this turn — a
			// deferred answer cannot carry a reference.
			session.tell(inbox, NOTIFY, [
				"room",
				"",
				roomIsListed(state.policy) ? LISTED : UNLISTED,
				false,
			]).catch((error) => {
				ctx.journal.note(`a listed notify to ${nick} failed`, error);
			});
			broadcast(ctx, state, "room", `${nick} joined (${state.members.length} here)`, "join", nick);
			if (!wasMember) {
				notifyLocalRoom(
					ctx,
					state,
					state.members.length === 1 ? "opened" : "count",
					state.members.length,
				);
			}
			// Who is here, to the arrival alone, carrying the roster as structured
			// trailing args ("roster" then each nick) so a client learns who arrived
			// before it without parsing the text. `subscribe` itself returns a bare
			// ack: success is the resolution, and a claimed nick is the rejection
			// above.
			//
			// A statement of who is present rather than a greeting: this is one
			// person being told about everyone, privately, which is the opposite of
			// a room addressing everyone about one person. It carries no count,
			// because the joining line broadcast a moment ago already does.
			session.tell(inbox, NOTIFY, [
				"room",
				rosterSaid(names),
				"roster",
				...names,
			]).catch((error) => {
				ctx.journal.note(`a roster notify to ${nick} failed`, error);
			});
			// Who is already away. One line each rather than a field on the roster,
			// because that is the same line every later change arrives on: a client
			// learns the state and the change through one path instead of two that
			// have to agree. Bounded by the roster, which the room already bounds.
			for (const m of state.members) {
				if (m.away === "" || m.nick === nick) continue;
				session.tell(inbox, NOTIFY, ["room", `${m.nick} is away: ${m.away}`, AWAY, m.nick, m.away]).catch(
					(error) => {
						ctx.journal.note(`an away notify to ${nick} failed`, error);
					},
				);
			}
			// What the room is about, if it is about anything. Sent only when there
			// is one, because "no topic" is the absence of this line rather than a
			// line saying nothing — a room that announced an empty topic to every
			// arrival would be telling each of them it had just been taken down.
			if (state.topic !== "") {
				session.tell(inbox, NOTIFY, ["room", `the topic is: ${state.topic}`, TOPIC, state.topic]).catch(
					(error) => {
						ctx.journal.note(`a topic notify to ${nick} failed`, error);
					},
				);
			}
			// Answering with the topic capability is how a member comes to hold it.
			// An older client ignores the answer and simply has no topic to set.
			return [member.seat, member.kind, topic] as Argument;
		}
		if (verb === CALLED) {
			if (args.length !== 0) throw new Error("called takes no arguments");
			// A link is not a name, but the room still has one while it is live:
			// a public room's directory name, or a private room's label. Empty
			// when a private room came back from a link with nobody left to
			// remember what it was called.
			return state.name;
		}
		if (verb === PRIVATE) {
			if (args.length !== 0) throw new Error("private takes no arguments");
			return roomIsListed(state.policy) ? "listed" : "private";
		}
		if (verb === ROOM_POLICY) {
			if (args.length !== 0) throw new Error("roomPolicy takes no arguments");
			return [state.policy.visibility, state.policy.entry, state.policy.speaking] as Argument;
		}
		if (verb === MANAGED_ROOM_IDENTITY) {
			if (args.length !== 0) throw new Error("managedRoomIdentity takes no arguments");
			if (links === null) throw new Error("this directory does not publish room managers");
			return links.managerIdentity(roomDurableIdentity(state)) as ReturnType<Behavior>;
		}
		if (verb === LINK) {
			if (args.length !== 0) throw new Error("link takes no arguments");
			if (links === null) throw new Error("this directory does not publish room links");
			const link = links.currentRoomLink(roomDurableIdentity(state), session);
			if (link === null) throw new Error("this room has no link; a room manager must create one");
			return link;
		}
		throw new Error(`room has no method ${verb}`);
	};
}
