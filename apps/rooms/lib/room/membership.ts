// The two facets of one live room membership, and the seat a room answers
// `subscribe` with.

import { type Argument, Ref, type Session } from "@glowcap/runtime";
import { throwAfterReleasingCapabilities } from "../argument_custody.ts";

export const ROOM_MEMBERSHIP_KINDS = ["observer", "participant"] as const;

export type RoomMembershipKind = typeof ROOM_MEMBERSHIP_KINDS[number];

export function isRoomMembershipKind(value: unknown): value is RoomMembershipKind {
	return typeof value === "string" && (ROOM_MEMBERSHIP_KINDS as readonly string[]).includes(value);
}

/** What `subscribe` answers: the membership seat, which facet it is, and the
 * topic authority when the room grants one. Every later membership verb
 * (`post`, `leave`, `away`, `typing`) goes to the seat, never to the room
 * reference the seat was answered for. */
export interface RoomMembershipAnswer {
	readonly seat: Ref;
	readonly kind: RoomMembershipKind;
	readonly topic: Ref | null;
}

/** Read a `subscribe` answer as it arrives. One reader, so every client
 * agrees about the shape and none can post on the room by mistake. A
 * malformed answer is refused without effect: every capability it carried is
 * released on `session` first, so a misbehaving room cannot leave imports
 * retained by a client that never accepted them. */
export function readMembershipAnswer(session: Session, answer: unknown): RoomMembershipAnswer {
	if (
		!Array.isArray(answer) || answer.length !== 3 || !(answer[0] instanceof Ref) ||
		!isRoomMembershipKind(answer[1]) || (answer[2] !== null && !(answer[2] instanceof Ref))
	) {
		throwAfterReleasingCapabilities(
			session,
			[answer as Argument],
			new Error("the room answered subscribe without one membership capability"),
		);
	}
	return { seat: answer[0], kind: answer[1], topic: answer[2] };
}
