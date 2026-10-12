// Room access controls render Rust policy values. Their cycle is a UI choice.
import { applicationModule } from "./application.ts";
import { isRoomPolicy, type RoomPolicy, type RoomPreset } from "../../lib/room/policy.ts";
export type { RoomPolicy, RoomPreset } from "../../lib/room/policy.ts";

const policies = new Map<RoomPreset, RoomPolicy>();
export function policyForRoomPreset(preset: RoomPreset): RoomPolicy {
	let policy = policies.get(preset);
	if (policy === undefined) {
		const raw: unknown = JSON.parse(applicationModule().roomPolicyForPreset(preset));
		if (!isRoomPolicy(raw)) throw new Error("the Rooms application answered an invalid room policy");
		policies.set(preset, policy = Object.freeze(raw));
	}
	return policy;
}
export const openRoomPolicy = (): RoomPolicy => policyForRoomPreset("open");
export const privateRoomPolicy = (): RoomPolicy => policyForRoomPreset("private");
export function roomPreset(policy: RoomPolicy): RoomPreset {
	return policy.visibility === "secret" ? "private" : policy.speaking === "moderated" ? "moderated" : "open";
}
export function standingOffered(offers: "observer" | "participant" | null): RoomPreset {
	return offers === "participant" ? "open" : "moderated";
}
export function nextRoomPreset(preset: RoomPreset): RoomPreset {
	return preset === "open" ? "moderated" : preset === "moderated" ? "private" : "open";
}
export function roomIsListed(policy: RoomPolicy): boolean {
	return policy.visibility === "listed";
}
export function roomPoliciesEqual(left: RoomPolicy, right: RoomPolicy): boolean {
	return left.visibility === right.visibility && left.entry === right.entry && left.speaking === right.speaking;
}
