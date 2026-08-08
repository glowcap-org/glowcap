---
id: ADR-0003
status: accepted
date: 2026-04-30
tags: [codec, syrup, capnp, wire-profile, goblins-interop, captp-version]
decision: Codecs encode one codec-neutral model; codec functions are stateless across sessions and take a per-call `CaptpVersion`. Version, codec, and interop target are separate axes. Two CapTP version jobs: `v1_0` / `"1.0"` is pancake's current Goblins 0.18.0 and pinned-suite interop floor, not an upstream maturity claim; `next` / `"pancake-next"` is pancake's forward private track for pancake-to-pancake (including Cap'n Proto sessions). Named offers (`Offer.goblins`, since renamed `Offer.v1_0Syrup`, / `Offer.native`) and `negotiate` settle the pair; ADR-0103 moved the production handshake offer from out-of-band configuration into signed locator hints while keeping `op:start-session`'s own shape at the baseline.
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0103]
---

# ADR-0003 Codec and interoperability posture

## Context

pancake's semantics are codec-neutral: every type in
[`src/ocapn/model/mod.zig`](../../../src/ocapn/model/mod.zig) carries the same
meaning regardless of which codec rendered it. But version, codec, and interop
target are different decisions. Two CapTP version jobs describe what makes a
shape legitimate:

- **Current interop floor (`v1_0` / `"1.0"`).** Bytes used by the pinned suite
  and Goblins 0.18.0. Goblins interop lives here as authenticated `v1_0` over
  Syrup. The wire token does not mean the upstream draft is released or frozen.
- **Pancake-forward (`next` / `"pancake-next"`).** pancake-to-pancake CapTP ahead of
  a new shared interop version number: pancake-namespaced on the wire, not an
  upstream OCapN maturity stage. Cap'n Proto sessions typically run here.
- **Codec plurality.** Syrup and Cap'n Proto are serialization choices for the
  selected version. A codec can be unsupported for a version if it cannot carry
  the required wire shape, but it does not decide the CapTP version.

(Earlier drafts of this ADR called the forward track `pre_spec` and framed it as
"upstream OCapN prerelease." That name collided with OCapN's "pre-specification"
suite language and wrongly denied that the track is pancake-private. The rename
to `next` / `"pancake-next"` and this rewrite correct that.)

A second axis is where CapTP-version state lives. Pinning it to a codec instance
ties version to construction; routing it per call keeps codec functions
stateless and makes version dispatch a parameter, not a constructor flag.

Engages the First Principles _protocol correctness before convenience_ and
_session state is authoritative_ (the codec renders; the session owns the
version it renders under).

## Decision

A per-call [`CaptpVersion`](../../../src/ocapn/model/mod.zig) is threaded into
encode/decode. Codec functions hold no cross-session state; the session caches
the negotiated version and supplies it.

The **Syrup** codec
([`src/ocapn/codec/syrup/`](../../../src/ocapn/codec/syrup/)) is the OCapN v1.0
interop codec. It translates between the codec-neutral `Message` model and the
Syrup shapes Goblins-compatible traffic requires, including resolver callbacks,
split GC, handoff descriptors, and error records. It supports `v1_0` and
`next`; the session version selects the V1.0 translation path when
`CaptpVersion` is `v1_0`.

The **Cap'n Proto** codec
([`src/ocapn/codec/capnp/`](../../../src/ocapn/codec/capnp/)) fills the
second-codec slot, hand-rolled against the wire format per
[ADR-0026](ADR-0026-hand-rolled-capnp-codec.md). It is a **fixed CapTP binary
codec** (Cap'n Proto framing), not CapNP-the-platform / bespoke schemas. It is
view-first and codec-neutral, and complete: all eleven `Message` arms and their
shared sub-trees encode and decode. It is engine-integrated and selectable on a
live session: a peer pair negotiates it, and the handshake plus all subsequent
traffic ride it through the codec-dispatch seam (`session.codec`), with the
session state machine staying codec-neutral.

**Offers and negotiation.**
[`engine.negotiation`](../../../src/ocapn/engine/negotiation.zig) exposes
`Offer.goblins()` (since renamed `Offer.v1_0Syrup()`) / `Offer.native()` and a
pure `negotiate(Offer, Offer)`.
`op:start-session` carries the baseline version string and no new operands.
ADR-0103 amends the production path: a peer states its preferred version, codec,
and feature set in the signed locator hints, and both sides run `negotiate` over
those offers. In-process pairing runs the same negotiation directly; the C ABI
entry `pancake_peer_new` stays pinned to Goblins `(v1_0, syrup)`.

## Scope (what this does not decide)

- The Goblins-canonical GC and abort wire shapes,
  [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md).
- Handoff crypto and three-party protocol,
  [ADR-0009](ADR-0009-three-party-handoff-substrate.md).
- The `op:start-session` substrate and bootstrap-fetch shape,
  [ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md).
- Discovery-carried offers outside the signed hello locator.

## Alternatives Considered

- **One global posture for every codec.** Rejected: forcing the Cap'n Proto slot
  to track Goblins shapes makes a pancake-to-pancake session pay compatibility
  overhead it has no reader for; forcing Syrup ahead of spec text breaks it as
  the interop path.
- **Carry `CaptpVersion` on a codec instance.** Rejected: version becomes
  constructor-pinned and version dispatch leaks into instance state. The
  per-call `CaptpVersion` keeps codec functions stateless and makes the V1.0 gate
  a version check.
- **Let feature negotiation pick the wire posture.** Rejected: version, codec,
  and feature selection are separate axes. Collapsing them would hide the
  difference between OCapN semantics and serialization.
- **A one-field `WireProfile` wrapper around `CaptpVersion`.** Rejected: one
  axis, one type. Codec and features already live as `CodecId` / `FeatureSet`.

## Consequences

- Codec functions are stateless; the per-call `CaptpVersion` is the only
  version-bearing encode/decode surface.
- A pancake-to-Goblins session sends `"1.0"` over Syrup. A native pancake-to-pancake
  session prefers `next` and Cap'n Proto via `Offer.native()`, falling back to
  `"1.0"` / Syrup when the partner only offers those.
- **Symmetric refusal:** if a codec cannot represent a value, it fails loud
  (`Error.UnsupportedArgument` and siblings) rather than dropping it, so the
  model stays the single source of representability. The live example is a wire
  value with no model home (`Null`/`Dict`/`Float32` fidelity, ADR-0021; Integer
  is arbitrary-precision per ADR-0049): it is refused on decode rather than
  mis-decoded or silently coerced. A codec that cannot render a value the model
  _does_ admit refuses the same way.
- Wire-version work is validated against the pancake-authored Syrup corpus versus
  upstream Syrup encoders (`zig build oracle-check`), not Goblins byte captures
  and not byte-equality between codecs. Live Goblins and `ocapn-conformance` are
  the external wire arms. Cap'n Proto layout is pinned by golden frames under
  `test/codec/capnp_fixtures/` (`zig build gen-capnp-fixtures` to regenerate).

## Cross-codec parity

The Cap'n Proto codec fills the second-codec seam, so cross-codec semantic
parity is backed rather than aspirational: the deliver/resolve and
bootstrap-fetch oracle cross-codec scenario traces produce identical
observable results on Syrup and Cap'n Proto. The two wire encodings differ, but
the observable behavior does not. Authenticated `op:start-session` verification
uses the
version-level canonical `<my-location …>` signing input, so Cap'n Proto sessions
do not get a weaker handshake path.

## Notes

[ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) settles the
Goblins-canonical GC/abort shapes inside the `v1_0` profile.
[ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) and
[ADR-0010](ADR-0010-payload-descriptor-discriminator.md) widen the model the
codecs render; both are additive and bump no version name.
