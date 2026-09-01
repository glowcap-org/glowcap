// The three public membership offers a Rooms manager can choose.

import * as z from "zod/mini";

export const ROOM_VISIBILITIES = ["listed", "secret"] as const;
export const ROOM_ENTRIES = ["open", "invite-only"] as const;
export const ROOM_SPEAKING = ["open", "moderated"] as const;

export type RoomVisibility = typeof ROOM_VISIBILITIES[number];
export type RoomEntry = typeof ROOM_ENTRIES[number];
export type RoomSpeaking = typeof ROOM_SPEAKING[number];

export const RoomPolicySchema = z.union([
	z.strictObject({ visibility: z.literal("listed"), entry: z.literal("open"), speaking: z.literal("open") }),
	z.strictObject({ visibility: z.literal("listed"), entry: z.literal("open"), speaking: z.literal("moderated") }),
	z.strictObject({
		visibility: z.literal("secret"),
		entry: z.literal("invite-only"),
		speaking: z.literal("moderated"),
	}),
]);

export type RoomPolicy = z.infer<typeof RoomPolicySchema>;

export const OPEN_ROOM_POLICY: RoomPolicy = {
	visibility: "listed",
	entry: "open",
	speaking: "open",
};

export const MODERATED_ROOM_POLICY: RoomPolicy = {
	visibility: "listed",
	entry: "open",
	speaking: "moderated",
};

export const PRIVATE_ROOM_POLICY: RoomPolicy = {
	visibility: "secret",
	entry: "invite-only",
	speaking: "moderated",
};

export type RoomPreset = "open" | "moderated" | "private";

export function roomPreset(policy: RoomPolicy): RoomPreset {
	if (policy.visibility === "secret") return "private";
	return policy.speaking === "moderated" ? "moderated" : "open";
}

/** The standing a room is in, read from what its public registration offers.
 *
 * `participant` is the open name. `observer` is the moderated one: the room is
 * listed and its name offers watching rather than speaking. A listed room that
 * offers nothing publicly is moderated too, because it is listed and does not
 * offer participation, which is what moderated means here.
 *
 * No answer is `private`: a private room is not listed, so nothing that reaches
 * a directory listing can be in that standing. A name absent from the listing
 * is either new or private, and the two are indistinguishable from outside,
 * which is the point of a private room. */
export function standingOffered(offers: "observer" | "participant" | null): RoomPreset {
	return offers === "participant" ? "open" : "moderated";
}

export function policyForRoomPreset(preset: RoomPreset): RoomPolicy {
	return preset === "private"
		? PRIVATE_ROOM_POLICY
		: preset === "moderated"
		? MODERATED_ROOM_POLICY
		: OPEN_ROOM_POLICY;
}

export function nextRoomPreset(preset: RoomPreset): RoomPreset {
	return preset === "open" ? "moderated" : preset === "moderated" ? "private" : "open";
}

export function isRoomVisibility(value: unknown): value is RoomVisibility {
	return typeof value === "string" && (ROOM_VISIBILITIES as readonly string[]).includes(value);
}

export function isRoomEntry(value: unknown): value is RoomEntry {
	return typeof value === "string" && (ROOM_ENTRIES as readonly string[]).includes(value);
}

export function isRoomSpeaking(value: unknown): value is RoomSpeaking {
	return typeof value === "string" && (ROOM_SPEAKING as readonly string[]).includes(value);
}

export function isRoomPolicy(value: unknown): value is RoomPolicy {
	return z.safeParse(RoomPolicySchema, value).success;
}

export function roomIsListed(policy: RoomPolicy): boolean {
	return policy.visibility === "listed";
}

export function roomPublicMayEnter(policy: RoomPolicy): boolean {
	return policy.entry === "open";
}

export function publicMembershipKind(policy: RoomPolicy): import("./membership.ts").RoomMembershipKind {
	return policy.speaking === "open" ? "participant" : "observer";
}

export function roomPoliciesEqual(left: RoomPolicy, right: RoomPolicy): boolean {
	return left.visibility === right.visibility && left.entry === right.entry && left.speaking === right.speaking;
}

export function parseRoomPolicy(value: unknown): RoomPolicy | null {
	if (!Array.isArray(value) || value.length !== 3) return null;
	const parsed = z.safeParse(RoomPolicySchema, {
		visibility: value[0],
		entry: value[1],
		speaking: value[2],
	});
	return parsed.success ? parsed.data : null;
}
