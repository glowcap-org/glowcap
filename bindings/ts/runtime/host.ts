// The CapTP host — multi-session CapTP product over the byte-fed host archive
// (libpancake_host, ADR-0072). Goblins' `mycapn` is two roles: the product maps
// to this `Host`, the router tables map to `engine.Node` that the host owns — never
// a single-type equation. The `PancakeHost` owns every decision: the retained
// identity, live-session directory, routing, transparent three-party
// redemption, and the gifter half's origination. What lives here is only what
// the embedder contract leaves to the binding: the host handle, the
// session-pointer → `Session` registry the action drain routes by, the vow table
// the drain's SETTLE/FAIL arms settle, the serialized action drain itself,
// gift-id entropy, and explicitly installed byte-channel connectors. The
// action decode+execute switch lives in `action.ts`; the pump lives in
// `pump.ts`; the dial executor lives in `dial.ts`. `session.ts` owns the
// `Session` they act on. `mod.ts` re-exports the public `Host`.

import { HOST_DURABLE_ENTROPY_LEN } from "@pancake/abi";
import { Context } from "./context.ts";
import { type CaptpVersion, type Codec, type FeatureSet } from "./value.ts";

export const DURABLE_SWISS_ENTROPY_BYTES = HOST_DURABLE_ENTROPY_LEN;
export interface HostOptions {
	codec?: Codec;
	captpVersion?: CaptpVersion;
	features?: FeatureSet;
	context?: Context;
	frameCap?: number;
	localTurnBudget?: number;
}
export type { SessionLimitOptions } from "./host/application.ts";

/** The CapTP host: one identity, one session directory, one routing and redeem
 * authority, shared by every session minted against it. Owns `engine.Node`
 * (the sans-io handoff router). The cross-host machinery lives in the Zig
 * core behind `libpancake_host` (ADR-0072); this is the host-idiom residue
 * over it — the `Session` registry, the vow table, the serialized action
 * drain that performs the I/O the host asks for (dial, flush, settle,
 * entropy), and explicitly installed byte-channel connectors. */

import { HostDrive } from "./host/drive.ts";

export class Host extends HostDrive {
	constructor(seed?: Uint8Array, opts: HostOptions = {}) {
		super(seed, opts);
	}
}
