// The OCapN value vocabulary: the reference kinds, the wrapper classes that make
// a native value marshal as a symbol/keyword/set/tagged record, the `Argument`
// union those form, the wire-grammar `Codec` selector, and the application
// layer (`Ref`/`AppValue`/`Behavior`/`Forward`) over them. Pure data with no I/O
// and no dependency on the rest of the binding beyond the generated ABI
// constants, so every other module builds on it. `mod.ts` re-exports the
// public members; `isReference` and the `near` constructor stay
// package-internal.

import { CODEC_CAPNP, CODEC_SYRUP } from "@pancake/abi";

export type Reference =
	| { kind: "near"; id: bigint; promise?: boolean }
	| { kind: "far"; id: bigint; promise?: boolean }
	| { kind: "promise"; answer: bigint }
	| { kind: "sturdy" }
	| { kind: "broken" };

export const near = (id: bigint, promise = false): Reference => ({
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
 * this enum); the values match `libpancake_net_transport_iroh`'s C ABI. A `tcp`
 * locator ignores it. */
export enum Reachability {
	Direct = 0,
	Discovery = 1,
	DiscoveryNoRelay = 2,
	LocalDiscovery = 3,
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
 * automatically. You never construct `near`/`far` references by hand. */
export class Ref {
	constructor(
		/** The wire reference this marshals to when passed as a `send` argument. */
		readonly reference: Reference,
	) {}
}

/** A value an application sends or receives: any OCapN `Argument`, a capability
 * `Ref`, or a list of those. The binding marshals `Ref`s to/from wire references
 * at the boundary, so applications work with capabilities as ordinary values. */
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

// Lift a decoded argument to the application vocabulary: a wire `Reference`
// becomes a `Ref` the app can `send` to or pass on; lists, set items, and a
// tagged record's value recurse, so a capability arrives as a `Ref` wherever
// it is nested.
export function liftArg(arg: Argument): AppValue {
	if (isReference(arg)) return new Ref(arg);
	if (Array.isArray(arg)) return arg.map(liftArg);
	if (arg instanceof PSet) {
		return new PSet(arg.items.map(liftArg));
	}
	if (arg instanceof Tagged) {
		return new Tagged(arg.tag, arg.value.map(liftArg));
	}
	return arg;
}

/** A behavior's tail-forward of its answer to another capability — the
 * binding's `Turn.forward` (ADR-0064). Return `new Forward(target, verb, args)`
 * from an actor and the host resolves the caller's answer from
 * `target <- verb(args)` instead of from a value: a target hosted on the same
 * connection composes in process (a caretaker over an attenuator forwards
 * through both), and a far target defers the answer onto the forwarded send's
 * reply. It is the whole mechanism behind `Session.caretaker` and
 * `Session.attenuate` — each proxy is an ordinary spawned actor whose
 * behavior forwards, or throws to refuse. Package-internal; applications reach
 * it through those verbs. */
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
