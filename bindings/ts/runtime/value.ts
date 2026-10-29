// The OCapN value vocabulary: the wrapper classes that make
// a plain JS value marshal as a symbol/keyword/set/tagged record, the `Argument`
// union those form, the wire-grammar `Codec` selector, and the application
// layer (`Ref`/`Behavior`/`Forward`) over them. Pure data with no I/O
// and no dependency on the rest of the binding beyond the generated ABI
// constants, so every other module builds on it. `mod.ts` re-exports the
// public members; `isReference` and the `near` constructor stay
// package-internal.

import {
	CAPTP_NEXT,
	CAPTP_V1_0,
	CODEC_CAPNP,
	CODEC_SYRUP,
	DEFAULT_CAPTP_VERSION as ABI_DEFAULT_CAPTP_VERSION,
	DEFAULT_CODEC as ABI_DEFAULT_CODEC,
	DEFAULT_FEATURES as ABI_DEFAULT_FEATURES,
	FEATURE_BASELINE,
	FEATURE_FULL,
	FEATURE_HANDOFF,
	FEATURE_MINIMUM,
	FEATURE_MULTI_LOCATION,
	FEATURE_PIPELINING,
	FEATURE_STURDYREF,
	FEATURE_UNTAG,
	FEATURE_WIRE_DELTA,
	INTERNAL,
	INTEROP_CAPTP_VERSION as ABI_INTEROP_CAPTP_VERSION,
	INTEROP_CODEC as ABI_INTEROP_CODEC,
	INVALID_ARGUMENT,
	IROH_REACH_DIRECT,
	IROH_REACH_DISCOVERY,
	IROH_REACH_DISCOVERY_NO_RELAY,
	IROH_REACH_LOCAL_DISCOVERY,
	OWN_CAPTP_VERSION as ABI_OWN_CAPTP_VERSION,
	OWN_CODEC as ABI_OWN_CODEC,
} from "@glowcap/abi";
import { GlowcapError } from "./errors.ts";

/** Tag a string so it marshals as an OCapN symbol rather than a string. */
export class Sym {
	constructor(public readonly value: string) {}
}

/** A string that marshals as an OCapN keyword. */
export class Kw {
	constructor(public readonly value: string) {}
}

/** A set of values (an OCapN set; elements may be non-primitive). */
export class PSet<T = Argument> {
	constructor(public readonly items: T[]) {}
}

/** An OCapN tagged record: a tag over a value list. */
export class Tagged<T = Argument> {
	constructor(public readonly tag: string, public readonly value: T[]) {}
}
export const tagged = <T = Argument>(tag: string, value: T[]): Tagged<T> => new Tagged(tag, value);

/** An OCapN Struct: unordered, uniquely named String fields. */
export class PStruct<T = Argument> {
	constructor(public readonly entries: Array<readonly [string, T]>) {}
}

// An argument is a plain JS value or a wrapper:
//   bigint (integer), number (float64), boolean, Uint8Array (bytes), BigInt64Array (list of integers), string,
//   Sym (symbol), Kw (keyword), Error (OCapN Error value), null (void), Ref, Argument[] (list),
//   PSet (set), Tagged, or PStruct. A RemotePromise this Host returned is
//   passable to `send`/`tell` in any state (ADR-0068): the Host passes it as
//   a capability for its answer. A peer's promise arrives as a Ref, and an
//   object this side hosts receives the RemotePromise itself. It enters the grammar
//   through the `PromiseArgument` brand rather than as a Promise type, which
//   would make the value grammar refer to itself through `then`.
export type Argument =
	| bigint
	| number
	| boolean
	| Uint8Array
	| BigInt64Array
	| string
	| Sym
	| Kw
	| Error
	| null
	| Ref
	| Argument[]
	| PSet
	| Tagged
	| PStruct
	| PromiseArgument;

/** The brand a `RemotePromise` carries as a passable send argument. */
export const promiseArgument: unique symbol = Symbol("glowcap.promiseArgument");
export interface PromiseArgument {
	readonly [promiseArgument]: true;
}

/** The wire grammar a CapTP session speaks: OCapN Syrup (the default) or
 * Cap'n Proto. A `Host` advertises its preference in signed locator hints and
 * the session settles the pair with its partner. */
export type Codec = "syrup" | "capnp";

/** The CapTP profile a session speaks (ADR-0001): `v1_0` is the interop floor
 * a Goblins vat and the upstream suite speak, `next` the glowcap-to-glowcap
 * track that `Offer.glowcap` prefers together with Cap'n Proto. A `Host`
 * advertises its preference in signed locator hints and the session settles
 * the pair with its partner. */
export type CaptpVersion = "v1_0" | "next";

export type FeatureName = "pipelining" | "handoff" | "wire_delta" | "sturdyref" | "untag" | "multi_location";
export type FeatureSet = "full" | "baseline" | "minimum" | number | readonly FeatureName[];

/** The profile a live session settled with its partner. `features` is the exact
 * mutually supported bit set, not the Host's offer. */
export interface SessionProfile {
	readonly captpVersion: CaptpVersion;
	readonly codec: Codec;
	readonly features: number;
}

const MAX_U32 = 0xffff_ffff;

export function codecFromId(codec: number, source = "generated default"): Codec {
	if (codec === CODEC_SYRUP) return "syrup";
	if (codec === CODEC_CAPNP) return "capnp";
	if (source === "generated default") {
		throw new TypeError(`glowcap ABI generated unknown default codec ${String(codec)}`);
	}
	throw new GlowcapError(INTERNAL, `glowcap ABI returned unknown ${source} codec ${String(codec)}`);
}

export function captpVersionFromId(version: number, source = "generated default"): CaptpVersion {
	if (version === CAPTP_V1_0) return "v1_0";
	if (version === CAPTP_NEXT) return "next";
	if (source === "generated default") {
		throw new TypeError(`glowcap ABI generated unknown default CapTP version ${String(version)}`);
	}
	throw new GlowcapError(INTERNAL, `glowcap ABI returned unknown ${source} CapTP version ${String(version)}`);
}

export function sessionProfileFromAbi(captpVersion: number, codec: number, features: number): SessionProfile {
	if (!Number.isInteger(features) || features < 0 || features > MAX_U32 || (features & ~FEATURE_FULL) !== 0) {
		throw new GlowcapError(INTERNAL, `glowcap ABI returned unknown session feature mask ${String(features)}`);
	}
	return {
		captpVersion: captpVersionFromId(captpVersion, "session"),
		codec: codecFromId(codec, "session"),
		features,
	};
}

function featureSetFromMask(features: number): FeatureSet {
	if (features === FEATURE_FULL) return "full";
	if (features === FEATURE_BASELINE) return "baseline";
	if (features === FEATURE_MINIMUM) return "minimum";
	return features;
}

export const DEFAULT_CODEC: Codec = codecFromId(ABI_DEFAULT_CODEC);
export const DEFAULT_CAPTP_VERSION: CaptpVersion = captpVersionFromId(ABI_DEFAULT_CAPTP_VERSION);
export const DEFAULT_FEATURES: FeatureSet = featureSetFromMask(ABI_DEFAULT_FEATURES);
export const OWN_CODEC: Codec = codecFromId(ABI_OWN_CODEC);
export const OWN_CAPTP_VERSION: CaptpVersion = captpVersionFromId(ABI_OWN_CAPTP_VERSION);
export const INTEROP_CODEC: Codec = codecFromId(ABI_INTEROP_CODEC);
export const INTEROP_CAPTP_VERSION: CaptpVersion = captpVersionFromId(ABI_INTEROP_CAPTP_VERSION);

export {
	FEATURE_BASELINE,
	FEATURE_FULL,
	FEATURE_HANDOFF,
	FEATURE_MINIMUM,
	FEATURE_MULTI_LOCATION,
	FEATURE_PIPELINING,
	FEATURE_STURDYREF,
	FEATURE_UNTAG,
	FEATURE_WIRE_DELTA,
};

export function codecId(codec: Codec): number {
	switch (codec) {
		case "syrup":
			return CODEC_SYRUP;
		case "capnp":
			return CODEC_CAPNP;
		default:
			throw new TypeError(`unknown OCapN codec ${String(codec)}`);
	}
}

export function captpVersionId(version: CaptpVersion): number {
	switch (version) {
		case "v1_0":
			return CAPTP_V1_0;
		case "next":
			return CAPTP_NEXT;
		default:
			throw new TypeError(`unknown CapTP version ${String(version)}`);
	}
}

export function featureMask(features: FeatureSet): number {
	if (features === "full") return FEATURE_FULL;
	if (features === "baseline") return FEATURE_BASELINE;
	if (features === "minimum") return FEATURE_MINIMUM;
	if (typeof features === "number") {
		const mask = features >>> 0;
		if (
			!Number.isInteger(features) ||
			features < 0 ||
			features > MAX_U32 ||
			(mask & ~(FEATURE_FULL >>> 0)) != 0
		) {
			throw new TypeError(`unknown OCapN feature mask ${String(features)}`);
		}
		return features;
	}
	let mask = 0;
	for (const feature of features) {
		switch (feature) {
			case "pipelining":
				mask |= FEATURE_PIPELINING;
				break;
			case "handoff":
				mask |= FEATURE_HANDOFF;
				break;
			case "wire_delta":
				mask |= FEATURE_WIRE_DELTA;
				break;
			case "sturdyref":
				mask |= FEATURE_STURDYREF;
				break;
			case "untag":
				mask |= FEATURE_UNTAG;
				break;
			case "multi_location":
				mask |= FEATURE_MULTI_LOCATION;
				break;
			default:
				throw new TypeError(`unknown OCapN feature ${String(feature)}`);
		}
	}
	return mask;
}

/** How an iroh endpoint becomes reachable, a required, explicit posture with no
 * default. The caller owns the reach/privacy tradeoff at every dialer and
 * constructor:
 * - `Direct`: dial by id + direct-address hints; relay-less, no discovery.
 * - `Discovery`: n0 relays + DNS discovery; dial by id alone.
 * - `DiscoveryNoRelay`: DNS discovery, no relays.
 * - `LocalDiscovery`: in-process address book (tests / same process).
 *
 * The type lives in the core so `connect` and `Host` name the posture without a
 * runtime dependency on the optional `@glowcap/iroh` package (which re-exports
 * this enum); the members read the generated `@glowcap/abi` mirror of
 * `libglowcap_net_transport_iroh`, so they cannot drift from the C ABI. A `tcp`
 * locator ignores it. */
export enum Reachability {
	Direct = IROH_REACH_DIRECT,
	Discovery = IROH_REACH_DISCOVERY,
	DiscoveryNoRelay = IROH_REACH_DISCOVERY_NO_RELAY,
	LocalDiscovery = IROH_REACH_LOCAL_DISCOVERY,
}

export function isReference(v: unknown): v is Ref {
	return v instanceof Ref;
}

// ── Capability layer: `Ref`, `Behavior`, and `Forward` over the one value
// vocabulary above. There is no second application tree to lower or lift.

let mintRef!: (id: bigint) => Ref;

/** A capability, a reference to an object you can `send` to, wherever it lives.
 *
 * You get a `Ref` two ways: `session.spawn(behavior)` (a local actor you host) or
 * `session.fetch(name)` (a capability a partner published). A `Ref` is opaque: pass
 * it as an argument to `send` and it marshals to the right wire reference
 * automatically. You never construct `near`/`far` references by hand.
 *
 * The bigint is an opaque Host identity. It is never a wire position and its
 * shape does not reveal whether the target is local, remote, or handoff-routed. */
export class Ref {
	private constructor(
		/** Opaque identity in the Host that minted this handle. */
		readonly id: bigint,
	) {}

	static {
		// Hand the private constructor to the module-scoped mint below, so
		// `refFromId` stays binding-internal without publishing a public
		// factory on the exported class.
		mintRef = (id) => new Ref(id);
	}

	// Set by Session.release. Not a memory flag: release spends the
	// application's retain. Other occurrences may keep the same Host id live,
	// so local dispatch and ABI projection both check this occurrence's flag.
	#released = false;

	/** True once {@link Session.release} has given this capability back. */
	get released(): boolean {
		return this.#released;
	}

	/** Whether `other` names the same Host capability. Each projected occurrence
	 * remains a distinct wrapper because it owns a distinct FFI retain; use
	 * this operation, not JavaScript wrapper identity (`===`), for OCapN Target
	 * equality. The opaque ids are process-unique across Hosts. */
	equals(other: Ref): boolean {
		return this.id === other.id;
	}

	/** Mark this handle spent. Called by {@link Session.release}; every use
	 * after it throws. */
	markReleased(): void {
		this.#released = true;
	}
}

/** Mint a Ref from the FFI Host's opaque id. Binding-internal: deliberately
 * not re-exported from `mod.ts`, so application code cannot manufacture a
 * FFI capability handle. */
export function refFromId(id: bigint): Ref {
	return mintRef(id);
}

/** Binding-internal use check shared by local dispatch and ABI projection.
 * Equality and release bookkeeping still read the immutable identity. */
export function liveRefId(ref: Ref): bigint {
	if (ref.released) {
		throw new GlowcapError(INVALID_ARGUMENT, "this capability was released and is no longer usable");
	}
	return ref.id;
}

/** A behavior's tail-forward of its answer to another capability, the
 * binding's `Turn.forward` (ADR-0016). A behavior that returns one has its
 * caller's answer resolved from `target <- verb(args)` instead of from a
 * value: a target hosted on the same connection composes in process (a
 * caretaker over an attenuator forwards through both), and a far target defers
 * the answer onto the forwarded send's reply. It is the whole mechanism behind
 * `Session.caretaker` and `Session.attenuate`, where each proxy is an ordinary
 * spawned actor whose behavior forwards, or throws to refuse.
 *
 * Package-internal, and not exported from `mod.ts`: applications
 * reach it through those two verbs rather than constructing one. It stays in
 * `Behavior`'s return union because the proxies this package spawns are
 * ordinary behaviors. */
export class Forward {
	constructor(
		readonly target: Ref,
		readonly verb: string | null,
		readonly args: Argument[],
	) {}
}

/** A hosted object's behavior: handle a `(verb, args)` call and return a reply.
 * Null selects no method. The empty string selects the empty symbol.
 * `args` may contain `Ref`s (capabilities you were handed). Throw to break the
 * caller's promise.
 *
 * A behavior may also return a promise (an `async` behavior): the binding
 * defers the turn's answer onto a resolver vow and settles it when the
 * promise does, so awaited work never stalls the host's turn loop. A
 * deferred reply may hand out capabilities this thread holds, and a value the
 * host refuses breaks the caller's promise. A rejection breaks the caller's
 * promise with the error's message. */
export type Behavior = (
	verb: string | null,
	args: Argument[],
) => Argument | Forward | void | PromiseLike<Argument | void>;
