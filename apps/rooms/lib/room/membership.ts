// The two facets of one live room membership, and the seat a room answers
// `subscribe` with.

import { type Argument, Ref, type Session } from "@glowcap/runtime";
import { throwAfterReleasingCapabilities } from "../argument_custody.ts";

export const ROOM_MEMBERSHIP_KINDS = ["observer", "participant"] as const;

export type RoomMembershipKind = typeof ROOM_MEMBERSHIP_KINDS[number];

export function isRoomMembershipKind(value: unknown): value is RoomMembershipKind {
	return typeof value === "string" && (ROOM_MEMBERSHIP_KINDS as readonly string[]).includes(value);
}

/** What `subscribe` answers: the membership seat, which kind of seat it is,
 * and two facets the room hands over or withholds. Every later membership
 * verb (`post`, `leave`, `away`, `typing`) goes to the seat, never to the
 * room reference the seat was answered for. `topic` is the authority to set
 * what the room is about. `files` is the authority to stage files against the
 * room's storage and publish them, which `attach` and `postFiles` go to; a
 * room that cannot hold bytes answers null there, and a client that holds
 * nothing draws no attach control. */
export interface RoomMembershipAnswer {
	readonly seat: Ref;
	readonly kind: RoomMembershipKind;
	readonly topic: Ref | null;
	readonly files: Ref | null;
}

/** Read a `subscribe` answer as it arrives. One reader, so every client
 * agrees about the shape and none can post on the room by mistake. A
 * malformed answer is refused without effect: every capability it carried is
 * released on `session` first, so a misbehaving room cannot leave imports
 * retained by a client that never accepted them. */
export function readMembershipAnswer(session: Session, answer: unknown): RoomMembershipAnswer {
	const facet = (value: unknown): value is Ref | null => value === null || value instanceof Ref;
	if (
		!Array.isArray(answer) || answer.length !== 4 || !(answer[0] instanceof Ref) ||
		!isRoomMembershipKind(answer[1]) || !facet(answer[2]) || !facet(answer[3])
	) {
		throwAfterReleasingCapabilities(
			session,
			[answer as Argument],
			new Error("the room answered subscribe without one membership capability"),
		);
	}
	return { seat: answer[0], kind: answer[1], topic: answer[2], files: answer[3] };
}
