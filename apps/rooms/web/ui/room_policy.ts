// Room access controls render Rust policy values. Their cycle is a UI choice.
import { invariant } from "../../lib/invariant.ts";
import { applicationModule } from "./application.ts";
import { isRoomPolicy, type RoomPolicy, type RoomPreset } from "../../lib/room/policy.ts";
export type { RoomPolicy, RoomPreset } from "../../lib/room/policy.ts";
export { nextRoomPreset, roomIsListed, roomPoliciesEqual, roomPreset, standingOffered } from "../../lib/room/policy.ts";

const policies = new Map<RoomPreset, RoomPolicy>();
export function policyForRoomPreset(preset: RoomPreset): RoomPolicy {
	let policy = policies.get(preset);
	if (policy === undefined) {
		const raw: unknown = JSON.parse(applicationModule().roomPolicyForPreset(preset));
		invariant(isRoomPolicy(raw), "the Rooms application answered an invalid room policy");
		policies.set(preset, policy = Object.freeze(raw));
	}
	return policy;
}
export const openRoomPolicy = (): RoomPolicy => policyForRoomPreset("open");
export const privateRoomPolicy = (): RoomPolicy => policyForRoomPreset("private");
