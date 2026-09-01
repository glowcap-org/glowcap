// The two facets of one live room membership.

export const ROOM_MEMBERSHIP_KINDS = ["observer", "participant"] as const;

export type RoomMembershipKind = typeof ROOM_MEMBERSHIP_KINDS[number];

export function isRoomMembershipKind(value: unknown): value is RoomMembershipKind {
	return typeof value === "string" && (ROOM_MEMBERSHIP_KINDS as readonly string[]).includes(value);
}
