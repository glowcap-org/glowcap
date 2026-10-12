// The Rooms fleet's coherent runtime posture.
//
// This is a pure options factory. Browser bootstrap can import it before
// @glowcap/web installs its wasm adapter, and every TypeScript Rooms Host
// receives the same pair without putting CapTP or codec constants in the room
// protocol vocabulary or UI.

import type { HostOptions } from "@glowcap/runtime";

export type RoomsHostPosture = "full" | "native-baseline" | "interop";

export function roomsHostOptions(posture: RoomsHostPosture = "full"): HostOptions {
	return posture === "full"
		? { profile: "native", features: "full" }
		: posture === "native-baseline"
		? { profile: "native", features: "baseline" }
		: { profile: "interop", features: "baseline" };
}
