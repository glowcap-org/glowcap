import { z } from "zod";

/**
 * OCapN vocabulary primitives, the atoms higher-level schemas
 * (`TimelineEvent`, ECS components) compose. Names track glowcap's
 * actual types in the Zig `model` and `session` layers. The `ocapn:`
 * IRI namespace exposes them for JSON-LD consumers.
 *
 * Session ends, sides, attribution, and the stage nodes they occupy,
 * live in [`session-end.ts`](./session-end.ts).
 */

/**
 * Implementation behind a peer. Open-ended (`z.string`) because
 * OCapN is implementation-plural. The renderer colors the well-known
 * profiles in `KNOWN_PROFILES` and falls back for anything else.
 * `ocapn:profile`.
 */
export const PeerProfile = z.string().min(1);
export type PeerProfile = z.infer<typeof PeerProfile>;

/** Spritely Goblins. A live feed carries it when a Goblins producer states it
 * on the record it publishes (`a_profile`), which the conformance peer's own
 * trace publisher does. Nothing ever concludes it: there is no observation
 * that names an implementation by what it is not, so a feed that is never
 * told stays unknown. `StageLedger` says why. */
export const GOBLINS_PROFILE = "goblins";

/** glowcap. A live feed reaches this verdict two ways, both at the hello:
 * a producer states it on the record it publishes (`a_profile`), and a
 * session that negotiated the `next` CapTP profile has a glowcap host at each
 * end, because that profile is glowcap-private (ADR-0001). The second is the
 * only implementation a feed ever concludes without being told. Publishing a
 * trace is not evidence of anything, since every implementation may publish
 * one. `StageLedger` is where both are read.
 *
 * The word itself is stated a sixth time here, once per glowcap binding and
 * once by this reader, and no generated tier can own it: the claim is about the
 * binding tier rather than about the core, so no Zig or C declaration carries
 * it. `zig build source-check` (`checkTraceViewerVocabulary`) is what keeps the
 * six in step, and it pins `GOBLINS_PROFILE` beside them so the two producers
 * cannot be collapsed into one. */
export const GLOWCAP_PROFILE = "glowcap";

export const KNOWN_PROFILES = [GOBLINS_PROFILE, GLOWCAP_PROFILE] as const;

/** What a peer's implementation is called while nobody has named it.
 *
 * Unknown is where every peer starts and where one the feed never speaks for
 * stays. It is a name rather than an absence because a peer always has an
 * implementation, the viewer has not been told which, and it is not
 * a final answer, because a peer's implementation is a temporal property like
 * its name: `PEER_TRAJECTORY.profile` is a keyframe track, so a peer drawn
 * unknown and later spoken for changes at the moment the viewer learns,
 * without rewriting what it knew before. */
export const UNNAMED_PROFILE = "other";

/** What a profile picker offers: the implementations this build knows
 *  by name, and the name for one nobody has stated.
 *
 *  It is an offer and not a domain. `PeerProfile` above is any
 *  non-empty string, so a document or a feed can carry an
 *  implementation this list has never heard of, and a picker holding
 *  such a value has to keep showing it. `EnumSelect` does, by adding
 *  whatever it was handed to whatever it was offered. Every surface
 *  that offers a profile reads this list, so there is one place a
 *  fourth implementation is named. */
export const PROFILE_OPTIONS: readonly PeerProfile[] = [
	...KNOWN_PROFILES,
	UNNAMED_PROFILE,
];

/** One profile the picker offers, as a type.
 *
 *  `PeerProfile` is every string, which is right for the field and useless to
 *  a table that has to cover the offer. This names the offer itself, so a
 *  `Record<ProfileOption, …>`, the Reference's profile section is one, fails
 *  to compile when a third implementation is named above. */
export type ProfileOption =
	| typeof KNOWN_PROFILES[number]
	| typeof UNNAMED_PROFILE;

/**
 * The netlayer a session's bytes ride, spelled the way a locator spells
 * it. Open-ended (`z.string`) for the reason `PeerProfile` above is:
 * CapTP is transport-agnostic and never names a transport, so the set of
 * netlayers is not the protocol's to close and a document or a feed may
 * carry one this build has never heard of. `ocapn:transport`.
 */
export const Transport = z.string().min(1);
export type Transport = z.infer<typeof Transport>;

/** What a transport picker offers: the netlayers this build knows by
 *  name.
 *
 *  It is an offer and not a domain, exactly as `PROFILE_OPTIONS` is,
 *  `Transport` above is any non-empty string, and a picker handed a
 *  netlayer that is not on this list keeps showing it, because
 *  `EnumSelect` adds whatever it was handed to whatever it was offered.
 *  Every surface that offers a transport reads this list, so there is
 *  one place a seventh netlayer is named. */
const KNOWN_TRANSPORTS = [
	"tcp",
	"keyed-tcp",
	"noise-tcp",
	"keyed-relay",
	"noise-relay",
	"iroh",
	"webrtc",
	"onion",
	"inproc",
] as const;

export const TRANSPORT_OPTIONS: readonly Transport[] = KNOWN_TRANSPORTS;

/** One netlayer the picker offers, as a type.
 *
 *  The list above is the offer and `Transport` is the field, which is every
 *  string. This names the offer, so a `Record<TransportOption, …>`, the
 *  Reference's transport section is one, fails to compile when a seventh
 *  netlayer is added to the list. */
export type TransportOption = typeof KNOWN_TRANSPORTS[number];

/**
 * Wire codec, negotiated per session. Open-ended for the same reason the
 * Zig `model.CodecId` is non-exhaustive: a recording can name a codec this
 * viewer cannot instantiate. The built-ins below are the authoring offer,
 * not the domain. `ocapn:Codec`.
 */
export const Codec = z.string().min(1);
export type Codec = z.infer<typeof Codec>;

const BUILTIN_CODECS = ["capnp", "syrup"] as const;

/** What a codec picker offers. A live feed can still carry another word, and
 *  `EnumSelect` keeps that current value visible until a reader changes it. */
export type BuiltinCodec = typeof BUILTIN_CODECS[number];
export const CODEC_OPTIONS: readonly BuiltinCodec[] = BUILTIN_CODECS;

/** The C ABI trace sentinel for a codec this ABI generation does not name.
 *  It is an observed value, not an authoring option. */
export const UNKNOWN_CODEC = "unknown";
export type CodecReferenceOption = BuiltinCodec | typeof UNKNOWN_CODEC;

export const CODEC_REFERENCE_OPTIONS: readonly CodecReferenceOption[] = [
	...CODEC_OPTIONS,
	UNKNOWN_CODEC,
];

/**
 * CapTP wire-profile version. `v1_0` is the spec-text version
 * (Goblins-canonical), and `next` is glowcap's forward private track, valid
 * only between glowcap peers (ADR-0001: it is a glowcap-namespaced interop
 * version, not an upstream OCapN maturity stage). `unknown` is an observed
 * trace sentinel for a producer that named a profile this viewer cannot.
 */
export const CaptpVersion = z.enum(["next", "v1_0", "unknown"]);
export type CaptpVersion = z.infer<typeof CaptpVersion>;

const BUILTIN_CAPTP_VERSIONS = ["next", "v1_0"] as const;
export type BuiltinCaptpVersion = typeof BUILTIN_CAPTP_VERSIONS[number];
export const CAPTP_VERSION_OPTIONS: readonly BuiltinCaptpVersion[] = BUILTIN_CAPTP_VERSIONS;

export const UNKNOWN_CAPTP_VERSION = "unknown";
export type CaptpVersionReferenceOption =
	| BuiltinCaptpVersion
	| typeof UNKNOWN_CAPTP_VERSION;

export const CAPTP_VERSION_REFERENCE_OPTIONS: readonly CaptpVersionReferenceOption[] = [
	...CAPTP_VERSION_OPTIONS,
	UNKNOWN_CAPTP_VERSION,
];

/**
 * How the handshake spells each version, which is the word a glowcap trace
 * reports (the Zig `model.CaptpVersion.wireString`). The tags above are this
 * document model's own names, chosen to read as identifiers. These are the
 * protocol's, and a live feed arrives speaking them.
 *
 * It is also what the app calls a version anywhere a person reads one: the
 * stage label, the Legend, the Inspector's field and its picker, the Build
 * tool bar, and the Reference. A tag is an identifier the document holds and
 * a reader has no use for, and a prettier third spelling would be one more
 * word for the same thing.
 *
 * The producers keep their own (`CAPTP_VERSION_WIRE` in
 * `bindings/ts/runtime/trace.ts`, and the same words inline in the Python,
 * Racket, and Rust trace modules). This one stays separate on three grounds:
 * the viewer consumes a schema no single implementation owns, it is its own
 * Deno scope that links no glowcap package, and this table is display text as
 * well as a wire reading, which the producers' is not. What separate must not
 * mean is free to drift, so `zig build source-check` requires this table to carry
 * every word `model.CaptpVersion.wireString` emits
 * (`checkTraceViewerVocabulary`), the same authority it holds the producers to.
 */
export const CAPTP_VERSION_WIRE: Record<BuiltinCaptpVersion, string> = {
	next: "glowcap-next",
	v1_0: "1.0",
};

export function captpVersionLabel(version: CaptpVersion): string {
	return version === UNKNOWN_CAPTP_VERSION ? UNKNOWN_CAPTP_VERSION : CAPTP_VERSION_WIRE[version];
}

/**
 * Read a version off the wire. Derived from `CAPTP_VERSION_WIRE` rather than
 * written out again, so the two directions cannot drift, and a version added
 * above is understood the moment it has a wire word.
 *
 * A producer that reported no version at all predates the field, and answers
 * `undefined` so the caller can apply the historical floor. A spelling this
 * viewer does not know is present data, so it answers the explicit unknown
 * sentinel rather than pretending to be the floor. `attributionForProvenance`
 * in `session-end.ts` reads its own wire word the same way, for the same reason.
 */
export function captpVersionFromWire(
	wire: unknown,
): CaptpVersion | undefined {
	if (wire === undefined) return undefined;
	if (typeof wire !== "string") return UNKNOWN_CAPTP_VERSION;
	for (const [version, spelling] of Object.entries(CAPTP_VERSION_WIRE)) {
		if (spelling === wire) return version as CaptpVersion;
	}
	return UNKNOWN_CAPTP_VERSION;
}

/**
 * Session lifecycle as the viewer draws it. The Zig `session.State` is
 * `negotiating` / `open` / `closed`, and `draining` is the viewer's own visual
 * stage for a session on its way out, not a protocol state.
 */
export const SessionState = z.enum([
	"negotiating",
	"open",
	"draining",
	"closed",
]);
export type SessionState = z.infer<typeof SessionState>;
