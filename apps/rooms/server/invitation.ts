// A one-claim entrance. Copies race on one stateful object; the winning receipt
// may retry without creating a second claim after a lost answer.

import { type Behavior, currentSession, type Ref, type Session } from "@pancake/runtime";
import { MAX_ROOM_INVITATIONS } from "../lib/limits.ts";
import { type OneShotRoomAdmission, oneShotRoomAdmission } from "../lib/room/admission.ts";
import type { RoomMembershipKind } from "../lib/room/membership.ts";
import { CLAIM_INVITATION } from "../lib/protocol.ts";
import { type RoomInvitation, type RoomState } from "./registry.ts";
import type { TroubleJournal } from "./journal.ts";
import type { RoomLiveIndex } from "./live_index.ts";

/** Retire one invitation: it refuses every later claim, and the room hands back
 * its own hold on the reference. The minter's import stays callable and stays
 * refused, because a released local capability is no longer the room's to hold
 * and revoking is what the behavior does, not what the bookkeeping does. */
export function retireInvitation(journal: TroubleJournal, invitation: RoomInvitation): void {
	invitation.active = false;
	if (invitation.ref !== null) {
		journal.release(invitation.session, invitation.ref, "retired room invitation");
	}
}

/** Retire every live invitation one membership minted, and forget the rows.
 *
 * An invitation is authority its minter chose to hand out, so it lasts exactly
 * as long as that choosing does. A membership that ends leaves nothing standing
 * that still lets somebody in on its say-so: not when the member leaves, not
 * when a steward asks them to, and not when their connection drops. Cutting the
 * membership cuts what it let in, which is the whole reason the room keeps who
 * minted what.
 *
 * A silent departure is not an ending. The same connection re-claiming its place
 * is one membership continuing, so what it minted continues too, which is the
 * cut `leaveMember` already makes for the same connection's uploads. */
export function retireInvitationsFrom(
	journal: TroubleJournal,
	state: RoomState,
	session: Session,
): void {
	for (const invitation of [...state.invitations]) {
		if (invitation.session !== session) continue;
		retireInvitation(journal, invitation);
		state.invitations.delete(invitation);
	}
}

export interface RoomInvitationIssuer {
	mint(owner: Session, kind: RoomMembershipKind): Ref;
}

/** Own the bound and lifetime of every live invitation issued for one room
 * generation. Admission remains with the entrance behavior supplied by the
 * room, while this owner prevents a stale invitation from resurrecting it. */
export function liveRoomInvitationIssuer(
	live: RoomLiveIndex,
	state: RoomState,
	entranceFor: (
		claimant: Session,
		current: RoomState,
		kind: RoomMembershipKind,
		admission: OneShotRoomAdmission,
	) => Ref,
): RoomInvitationIssuer {
	return {
		mint(owner, kind) {
			if (state.invitations.size >= MAX_ROOM_INVITATIONS) {
				throw new Error(`this room already holds ${MAX_ROOM_INVITATIONS} live invitations`);
			}
			const roomId = state.key;
			const generation = state.entryId;
			const holding: RoomInvitation = { session: owner, ref: null, active: true };
			const invitation = owner.spawn(oneShotInvitationBehavior(
				(claimant, admission) => {
					const current = live.rooms.get(roomId);
					if (current == null || current.entryId !== generation) {
						throw new Error("this room invitation has ended");
					}
					return entranceFor(claimant, current, kind, admission);
				},
				() => holding.active && live.rooms.get(roomId)?.entryId === generation,
			));
			holding.ref = invitation;
			state.invitations.add(holding);
			return invitation;
		},
	};
}

export function oneShotInvitationBehavior(
	entranceFor: (session: Session, admission: OneShotRoomAdmission) => import("@pancake/runtime").Ref,
	active: () => boolean,
	sessionFor: () => Session | null = currentSession,
): Behavior {
	let winningReceipt: string | null = null;
	const admission = oneShotRoomAdmission();
	return (verb, args) => {
		const session = sessionFor();
		if (session === null) throw new Error("a room invitation is reachable only during a session turn");
		if (!active()) throw new Error("this room invitation has ended");
		if (verb !== CLAIM_INVITATION) throw new Error(`a room invitation has no method ${verb}`);
		if (args.length !== 1 || typeof args[0] !== "string" || !/^[0-9a-f]{32}$/.test(args[0])) {
			throw new Error("claimInvitation takes one 128-bit lowercase hexadecimal receipt");
		}
		if (winningReceipt !== null && winningReceipt !== args[0]) {
			throw new Error("this room invitation was claimed already");
		}
		winningReceipt = args[0];
		return entranceFor(session, admission);
	};
}
