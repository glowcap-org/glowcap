// The CapTP host: multi-session CapTP product over the byte-fed host archive
// (libglowcap_host). Goblins' `mycapn` is two roles: the product maps
// to this `Host`, the router tables map to `engine.Node` that the host owns, and never
// a single-type equation. The `GlowcapHost` owns every decision: the retained
// identity, live-session directory, routing, transparent three-party
// redemption, and the gifter half's origination. What lives here is only what
// the embedder contract leaves to the binding: the host handle, the
// session-pointer → `Session` registry the action drain routes by, the vow table
// the drain's SETTLE/FAIL arms settle, the serialized action drain itself,
// gift-id entropy, and explicitly installed byte-channel connectors. The
// action decode+execute switch lives in `action.ts`; the pump lives in
// `pump.ts`; the dial executor lives in `dial.ts`. `session.ts` owns the
// `Session` they act on. `mod.ts` re-exports the public `Host`.

import { HOST_DURABLE_ENTROPY_LEN } from "@glowcap/abi";
import { Context } from "./context.ts";
import { type CaptpVersion, type Codec, type FeatureSet } from "./value.ts";

/** The exact length in bytes of the durable entropy a Host accepts for minting swiss numbers, as the core defines it. */
export const DURABLE_SWISS_ENTROPY_BYTES = HOST_DURABLE_ENTROPY_LEN;
/** A coherent codec and CapTP version pair authored by the core. `interop` is the pair that speaks to other OCapN
 * implementations, and `glowcap` is the pair for glowcap-to-glowcap peers. */
export type HostProfile = "interop" | "glowcap";
/** Options for constructing a `Host`. Choose a `profile`, or set `codec` and `captpVersion` directly, because a profile
 * refuses either. `features`, `context`, `frameCap`, and `localTurnBudget` apply either way. */
export interface HostOptions {
	/** Select a core-authored coherent codec/version pair. */
	profile?: HostProfile;
	codec?: Codec;
	captpVersion?: CaptpVersion;
	features?: FeatureSet;
	context?: Context;
	frameCap?: number;
	localTurnBudget?: number;
}
export type { SessionLimitOptions } from "./host/application.ts";

import { HostDrive } from "./host/drive.ts";

/** The CapTP host: one identity, one session directory, one routing and redeem
 * authority, shared by every session minted against it. Owns `engine.Node`
 * (the sans-io handoff router). The cross-host machinery lives in the Zig
 * core behind `libglowcap_host`. This is the host-idiom residue
 * over it: the `Session` registry, the vow table, the serialized action
 * drain that performs the I/O the host asks for (dial, flush, settle,
 * entropy), and explicitly installed byte-channel connectors. */
export class Host extends HostDrive {
	constructor(seed?: Uint8Array, opts: HostOptions = {}) {
		super(seed, opts);
	}
}
