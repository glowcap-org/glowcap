// The CapTP face of one IRC-bridged room's member citizenship.

import { type Argument, type Behavior, currentSession, type Session } from "@pancake/runtime";
import type { IrcChannelMembership } from "../../irc/bridge/reader_connection.ts";
import type { IrcBridgeRoom } from "../../irc/bridge/room.ts";
import { type BridgeForm, readBridgeAnswers } from "../../lib/bridge/form.ts";
import {
	IRC_ACCOUNT_FIELD,
	IRC_DISCONNECT_ACTION,
	IRC_LINK_ACTION,
	IRC_NICK_FIELD,
	IRC_PASSWORD_FIELD,
} from "../../irc/bridge/identity_form.ts";
import type { SaslPlainCredentials } from "../../irc/registration.ts";
import { validateIrcNick, validateSaslPlain } from "../../irc/registration.ts";
import { LEAVE, LINK, MEMBERSHIP_KIND, MINT_INVITATION, POST, SUBSCRIBE } from "../../lib/protocol.ts";
import { BRIDGE_FORM, SUBMIT_BRIDGE_FORM } from "../../lib/protocol_irc.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../../lib/argument_custody.ts";
import { READ_ONLY_MEMBERSHIP, ROOM_RETIRED, RoomError } from "../../lib/errors.ts";
import { isRoomMembershipKind } from "../../lib/room/membership.ts";
import { oneShotInvitationBehavior } from "../invitation.ts";
import { MAX_ROOM_INVITATIONS } from "../../lib/limits.ts";

export interface IrcSeatIdentity {
	readonly nick: string;
	readonly sasl?: SaslPlainCredentials;
}

export interface MemberBridge {
	readonly room: IrcBridgeRoom;
	stopped: boolean;
	readonly invitations: Set<{ session: Session; ref: import("@pancake/runtime").Ref | null; active: boolean }>;
}

export interface MemberBridgeOperations<Bridge extends MemberBridge, Seat> {
	network(bridge: Bridge): { name: string; tls: boolean };
	seat(bridge: Bridge, session: Session, nick: string): void;
	membership(bridge: Bridge, session: Session): Promise<IrcChannelMembership>;
	seatFor(bridge: Bridge, session: Session): Seat | null;
	replaceIdentity(seat: Seat, identity: IrcSeatIdentity): Promise<void>;
	/** The form this bridge wants drawn for one seat as it stands. Answered by
	 * the bridge rather than assembled here: what a form asks for is the
	 * bridge's, and this file only carries it across. */
	identityForm(bridge: Bridge, seat: Seat): BridgeForm;
	disconnectIdentity(seat: Seat): void;
	retire(bridge: Bridge, session: Session): void;
}

export interface MemberBridgeAuthority {
	link(session: Session): string;
}

function bridgeMembershipBehavior<Bridge extends MemberBridge, Seat>(
	held: Bridge,
	operations: MemberBridgeOperations<Bridge, Seat>,
	base: Behavior,
	memberSession: Session,
): Behavior {
	return (verb, args) => {
		const caller = currentSession();
		if (caller == null) throw new Error("an IRC gateway membership is reachable only during a session turn");
		if (held.stopped) {
			if (verb === LEAVE) return base(verb, args);
			throw new RoomError(ROOM_RETIRED, "this IRC bridge has been parted");
		}
		if (verb === POST) {
			const post = held.room.preparePost(memberSession, args);
			return operations.membership(held, memberSession)
				.then((membership) =>
					post.text.startsWith("/me ") ? membership.action(post.text.slice(4)) : membership.say(post.text)
				)
				.then(() => held.room.commitPost(post)) as ReturnType<Behavior>;
		}
		if (verb === MINT_INVITATION) {
			if (base(MEMBERSHIP_KIND, []) !== "participant") {
				throw new RoomError(READ_ONLY_MEMBERSHIP, "an observer membership cannot invite participants");
			}
			if (args.length !== 1 || !isRoomMembershipKind(args[0])) {
				throw new Error("mintInvitation takes one observer or participant membership kind");
			}
			const kind = args[0];
			if (held.invitations.size >= MAX_ROOM_INVITATIONS) {
				throw new Error(`this IRC bridge already holds ${MAX_ROOM_INVITATIONS} live invitations`);
			}
			const holding = { session: caller, ref: null as import("@pancake/runtime").Ref | null, active: true };
			const behavior = oneShotInvitationBehavior(
				(claimant, admission) =>
					claimant.spawn(held.room.roomBehavior({
						wrapMembership: (next, owner) => bridgeMembershipBehavior(held, operations, next, owner),
						membershipKind: kind,
						admission,
					})),
				() => holding.active && !held.stopped,
			);
			const invitation = caller.spawn(behavior);
			holding.ref = invitation;
			held.invitations.add(holding);
			return invitation;
		}
		if (verb === BRIDGE_FORM) {
			if (args.length !== 0) throw new Error("bridgeForm takes no arguments");
			const seat = operations.seatFor(held, memberSession);
			// No seat means this bridge is asking nothing of this member, which is
			// an ordinary answer rather than a refusal: a Matrix bridge that
			// puppets its users would answer this way always.
			if (seat == null) return null;
			return JSON.stringify(operations.identityForm(held, seat));
		}
		if (verb === SUBMIT_BRIDGE_FORM) {
			if (args.length !== 2 || typeof args[0] !== "string" || typeof args[1] !== "string") {
				throw new Error("submitBridgeForm needs an action and its answers");
			}
			const network = operations.network(held);
			const seat = operations.seatFor(held, memberSession);
			if (seat == null) throw new Error("choose an IRC identity from a room you are seated in");
			const answers = readBridgeAnswers(args[1]);
			if (args[0] === IRC_DISCONNECT_ACTION) {
				operations.disconnectIdentity(seat);
				return `you now appear only in Rooms across ${network.name}`;
			}
			if (args[0] !== IRC_LINK_ACTION) throw new Error(`this bridge form has no action ${args[0]}`);
			// A form says what a field is called and whether it is required. What
			// makes a nick or a password valid on IRC is IRC's, and is checked here
			// whatever a client believed about the form it drew.
			const nick = answers[IRC_NICK_FIELD] ?? "";
			const account = answers[IRC_ACCOUNT_FIELD] ?? "";
			const password = answers[IRC_PASSWORD_FIELD] ?? "";
			validateIrcNick(nick);
			let identity: IrcSeatIdentity = { nick };
			if (account !== "" || password !== "") {
				if (!network.tls) {
					throw new Error("this bridge runs without TLS; a registered account needs an encrypted path");
				}
				const sasl = { account, password };
				validateSaslPlain(sasl);
				identity = { nick, sasl };
			}
			return operations.replaceIdentity(seat, identity).then(() =>
				account === ""
					? `you now speak on IRC as <${nick}> across ${network.name}`
					: account === nick
					? `you now speak on IRC as <${nick}> across ${network.name}, logged in`
					: `you now speak on IRC as <${nick}> across ${network.name}, logged into ${account}`
			) as ReturnType<Behavior>;
		}
		if (verb === LEAVE) {
			const answer = base(verb, args);
			operations.retire(held, memberSession);
			return answer;
		}
		return base(verb, args);
	};
}

export function memberBridgeBehavior<Bridge extends MemberBridge, Seat>(
	held: Bridge,
	operations: MemberBridgeOperations<Bridge, Seat>,
	authority: MemberBridgeAuthority | null = null,
): { roomBehavior(): Behavior } {
	return {
		roomBehavior: (): Behavior => {
			const inner = held.room.roomBehavior({
				wrapMembership: (base, memberSession) =>
					bridgeMembershipBehavior(held, operations, base, memberSession),
			});
			return (verb: string, args: Argument[]): ReturnType<Behavior> => {
				const session = currentSession();
				if (session == null) throw new Error("an IRC gateway room is reachable only during a session turn");
				if (verb !== SUBSCRIBE && hasCapabilityArguments(args)) {
					throwAfterReleasingCapabilities(
						session,
						args,
						new Error(`IRC bridge room ${verb} does not take capability arguments`),
					);
				}
				if (held.stopped) {
					throw new RoomError(ROOM_RETIRED, "this IRC bridge has been parted");
				}
				if (verb === LINK) {
					if (args.length !== 0) throw new Error("link takes no arguments");
					if (authority == null) throw new Error("this IRC bridge has no durable entry authority");
					return authority.link(session);
				}
				if (verb === SUBSCRIBE) {
					const answer = inner(verb, args);
					operations.seat(held, session, typeof args[0] === "string" ? args[0] : "");
					return answer;
				}
				return inner(verb, args);
			};
		},
	};
}
