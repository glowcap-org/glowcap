// The three public membership offers a Rooms manager can choose.

import * as z from "zod/mini";

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
 * listed and its name offers watching and not speaking. A listed room that
 * offers nothing publicly is moderated too, because it is listed without an
 * offer to participate.
 *
 * No answer is `private`: a private room is not listed, so nothing that reaches
 * a directory listing can be in that standing. A name absent from the listing
 * is either new or private, and the two look the same from outside, which is
 * the point of a private room. */
export function standingOffered(offers: "observer" | "participant" | null): RoomPreset {
	return offers === "participant" ? "open" : "moderated";
}

export function nextRoomPreset(preset: RoomPreset): RoomPreset {
	return preset === "open" ? "moderated" : preset === "moderated" ? "private" : "open";
}

export function isRoomPolicy(value: unknown): value is RoomPolicy {
	return z.safeParse(RoomPolicySchema, value).success;
}

export function roomIsListed(policy: RoomPolicy): boolean {
	return policy.visibility === "listed";
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
