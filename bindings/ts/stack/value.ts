// The OCapN value vocabulary: the reference kinds, the wrapper classes that make
// a native value marshal as a symbol/keyword/set/tagged record, the `Argument`
// union those form, the wire-grammar `Codec` selector, and the application
// layer (`Ref`/`AppValue`/`Behavior`/`Forward`) over them. Pure data with no I/O
// and no dependency on the rest of the binding beyond the generated ABI
// constants, so every other module builds on it. `mod.ts` re-exports the
// public members; `isReference` and the `near` constructor stay
// package-internal.

import {
	CODEC_CAPNP,
	CODEC_SYRUP,
	IROH_REACH_DIRECT,
	IROH_REACH_DISCOVERY,
	IROH_REACH_DISCOVERY_NO_RELAY,
	IROH_REACH_LOCAL_DISCOVERY,
} from "@pancake/abi";

export type Reference =
	| { kind: "near"; id: bigint; promise?: boolean }
	| { kind: "far"; id: bigint; promise?: boolean }
	| { kind: "promise"; answer: bigint }
	| { kind: "sturdy" }
	| { kind: "broken" };

/** The wire identity a capability in hand takes: a local `near` export or a
 * partner-held `far` token. These are the only two shapes a {@link Ref} holds. A
 * pipeline promise, sturdyref, or broken reference is not a capability you hold,
 * so those three {@link Reference} kinds are excluded here. Mirrors the Python
 * binding's `Near | Far` and the fetch classifier `asLiveRef`. */
export type LiveReference =
	| { kind: "near"; id: bigint; promise?: boolean }
	| { kind: "far"; id: bigint; promise?: boolean };

/** A wire reference that is not a capability in hand: a pipeline promise, a
 * sturdyref, or a broken reference. These arrive in the application vocabulary
 * as plain wire values, never as a {@link Ref}. */
export type NonLiveReference = Exclude<Reference, LiveReference>;

export const near = (id: bigint, promise = false): LiveReference => ({
	kind: "near",
	id,
	promise,
});

/** Tag a string so it marshals as an OCapN symbol rather than a string. */
export class Sym {
	constructor(public readonly value: string) {}
}

/** A string that marshals as an OCapN keyword. */
export class Kw {
	constructor(public readonly value: string) {}
}

/** A set of values (an OCapN set; elements may be non-primitive). The element
 * type is a parameter so the wire vocabulary (`PSet<Argument>`) and the
 * application vocabulary (`PSet<AppValue>`, whose elements may be capability
 * `Ref`s) are each exact, with no `as` cast hiding a nested reference. */
export class PSet<T = Argument> {
	constructor(public readonly items: T[]) {}
}

/** An OCapN tagged record: a tag over a value list. The value type is a
 * parameter for the same reason as `PSet`, so a capability nested one container
 * deep is a first-class `Ref` in the application vocabulary. */
export class Tagged<T = Argument> {
	constructor(public readonly tag: string, public readonly value: T[]) {}
}
export const tagged = <T = Argument>(tag: string, value: T[]): Tagged<T> => new Tagged(tag, value);

// An argument is a native value or a wrapper:
//   bigint (integer), number (float64), boolean, Uint8Array (bytes), string,
//   Sym (symbol), Kw (keyword), null (void), Reference, Argument[] (list),
//   PSet (set), or Tagged.
export type Argument =
	| bigint
	| number
	| boolean
	| Uint8Array
	| string
	| Sym
	| Kw
	| null
	| Reference
	| Argument[]
	| PSet
	| Tagged;

/** The wire grammar a CapTP session speaks: OCapN Syrup (the default) or
 * Cap'n Proto. Both ends of a session must carry the same value; a `Host`
 * remembers its codec so every session it mints negotiates in it. */
export type Codec = "syrup" | "capnp";

export function codecId(codec: Codec): number {
	return codec === "capnp" ? CODEC_CAPNP : CODEC_SYRUP;
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
 * runtime dependency on the optional `@pancake/iroh` package (which re-exports
 * this enum); the members read the generated `@pancake/abi` mirror of
 * `libpancake_net_transport_iroh`, so they cannot drift from the C ABI. A `tcp`
 * locator ignores it. */
export enum Reachability {
	Direct = IROH_REACH_DIRECT,
	Discovery = IROH_REACH_DISCOVERY,
	DiscoveryNoRelay = IROH_REACH_DISCOVERY_NO_RELAY,
	LocalDiscovery = IROH_REACH_LOCAL_DISCOVERY,
}

export function isReference(v: unknown): v is Reference {
	return typeof v === "object" && v !== null && "kind" in v &&
		["near", "far", "promise", "sturdy", "broken"].includes(
			(v as Reference).kind,
		);
}

// ── Application value layer: a capability `Ref` over a wire reference, the
// `AppValue` union, the `Behavior` type, and the lower/lift pair between
// `AppValue` and the wire `Argument`. Built on the value vocabulary above.

/** A capability, a reference to an object you can `send` to, wherever it lives.
 *
 * You get a `Ref` two ways: `conn.spawn(behavior)` (a local actor you host) or
 * `conn.fetch(name)` (a capability a partner published). A `Ref` is opaque: pass
 * it as an argument to `send` and it marshals to the right wire reference
 * automatically. You never construct `near`/`far` references by hand.
 *
 * A `Ref` names only a `near` export or a `far` token — the two shapes a
 * capability in hand takes. A promise, sturdyref, or broken reference is not one
 * (a pipeline promise is a {@link RemotePromise}, and the rest arrive as plain
 * wire values), so a `Ref`'s reference is a {@link LiveReference}. */
export class Ref {
	constructor(
		/** The wire reference this marshals to when passed as a `send` argument. */
		readonly reference: LiveReference,
	) {}
}

/** A value an application sends or receives: any OCapN `Argument`, a capability
 * `Ref`, or a list of those. The binding marshals a `near`/`far` reference
 * to/from a `Ref` at the boundary, so applications work with capabilities as
 * ordinary values. A promise, sturdyref, or broken reference is not a capability
 * in hand, so it arrives as a plain wire `Reference` rather than a `Ref`. */
export type AppValue =
	| bigint
	| number
	| boolean
	| Uint8Array
	| string
	| Sym
	| Kw
	| null
	| Ref
	| NonLiveReference
	| AppValue[]
	| PSet<AppValue>
	| Tagged<AppValue>;

// Lower an application value to the wire vocabulary: a `Ref` becomes its
// underlying `Reference`; everything else passes through, recursing into
// lists, set items, and a tagged record's value so a capability nested in any
// of them marshals.
export function lowerArg(arg: AppValue): Argument {
	if (arg instanceof Ref) return arg.reference;
	if (Array.isArray(arg)) return arg.map(lowerArg);
	if (arg instanceof PSet) {
		return new PSet(arg.items.map(lowerArg));
	}
	if (arg instanceof Tagged) {
		return new Tagged(arg.tag, arg.value.map(lowerArg));
	}
	return arg;
}

// Lift a decoded argument to the application vocabulary: a `near`/`far`
// reference becomes a `Ref` the app can `send` to or pass on; a promise,
// sturdyref, or broken reference is not a capability in hand, so it passes
// through as a plain wire `Reference`. Lists, set items, and a tagged record's
// value recurse, so a capability arrives as a `Ref` wherever it is nested.
export function liftArg(arg: Argument): AppValue {
	if (isReference(arg)) {
		return arg.kind === "near" || arg.kind === "far" ? new Ref(arg) : arg;
	}
	if (Array.isArray(arg)) return arg.map(liftArg);
	if (arg instanceof PSet) {
		return new PSet(arg.items.map(liftArg));
	}
	if (arg instanceof Tagged) {
		return new Tagged(arg.tag, arg.value.map(liftArg));
	}
	return arg;
}

/** A behavior's tail-forward of its answer to another capability, the
 * binding's `Turn.forward` (ADR-0064). A behavior that returns one has its
 * caller's answer resolved from `target <- verb(args)` instead of from a
 * value: a target hosted on the same connection composes in process (a
 * caretaker over an attenuator forwards through both), and a far target defers
 * the answer onto the forwarded send's reply. It is the whole mechanism behind
 * `Session.caretaker` and `Session.attenuate`, where each proxy is an ordinary
 * spawned actor whose behavior forwards, or throws to refuse.
 *
 * Package-internal, and deliberately not exported from `mod.ts`: applications
 * reach it through those two verbs rather than constructing one. It stays in
 * `Behavior`'s return union because the proxies this package spawns are
 * ordinary behaviors. */
export class Forward {
	constructor(
		readonly target: Ref,
		readonly verb: string,
		readonly args: AppValue[],
	) {}
}

/** A hosted object's behavior: handle a `(verb, args)` call and return a reply.
 * `args` may contain `Ref`s (capabilities you were handed). Throw to break the
 * caller's promise. */
export type Behavior = (verb: string, args: AppValue[]) => AppValue | Forward | void;
