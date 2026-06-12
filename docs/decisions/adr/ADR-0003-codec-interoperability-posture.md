---
id: ADR-0003
status: accepted
date: 2026-04-30
tags: [codec, syrup, capnp, wire-profile, goblins-interop, captp-version]
decision: Codecs encode one codec-neutral model; codec functions are stateless across sessions and take a per-call `WireProfile` carrying the negotiated `CaptpVersion`. Profile, codec, and interop target are separate axes: Goblins interop pins authenticated `v1_0` over Syrup, while pancake-to-pancake sessions can negotiate `v1_0` or `pre_spec` and Syrup or Cap'n Proto where supported. `pre_spec` is the upstream OCapN prerelease profile, not a pancake-private extension bucket.
supersedes: []
superseded_by: []
---

# ADR-0003 Codec and interoperability posture

## Context

pancake's semantics are codec-neutral: every type in [`src/ocapn/model/mod.zig`](../../../src/ocapn/model/mod.zig) carries the same meaning regardless of which codec rendered it. But profile, codec, and interop target are different decisions. Three regions describe what makes a shape legitimate:

- **Released OCapN.** Bytes any OCapN v1.0 peer following the spec accepts. Goblins interop lives here today as authenticated `v1_0` over Syrup.
- **Upstream OCapN in progress.** Shapes from OCapN working-group discussion, meeting minutes, upstream spec/project direction, or Spritely/Goblins protocol work that have not landed in a released profile yet. The `pre_spec` profile lives here.
- **Codec plurality.** Syrup and Cap'n Proto are serialization choices for the selected profile. A codec can be unsupported for a profile if it cannot carry the required wire shape, but it does not decide the protocol profile.

A second axis is where CapTP-version state lives. Pinning it to a codec instance ties version to construction; routing it per call keeps codec functions stateless and makes wire-profile dispatch a parameter, not a constructor flag.

Engages the First Principles *protocol correctness before convenience* and *session state is authoritative* (the codec renders; the session owns the profile it renders under).

## Decision

A [`WireProfile`](../../../src/ocapn/model/mod.zig) carries the negotiated `CaptpVersion` as a per-call parameter threaded into encode/decode. Codec functions hold no cross-session state; the session caches the negotiated profile and supplies it.

The **Syrup** codec ([`src/ocapn/codec/syrup/`](../../../src/ocapn/codec/syrup/)) is the OCapN v1.0 interop codec. It translates between the codec-neutral `Message` model and the Syrup shapes Goblins-compatible traffic requires, including resolver callbacks, split GC, handoff descriptors, and error records. It supports `v1_0` and `pre_spec`; the session profile selects the V1.0 translation path when `CaptpVersion` is `v1_0`.

The **Cap'n Proto** codec ([`src/ocapn/codec/capnp/`](../../../src/ocapn/codec/capnp/)) fills the second-codec slot, hand-rolled against the wire format per [ADR-0026](ADR-0026-hand-rolled-capnp-codec.md). It is view-first and codec-neutral, and complete: all ten `Message` arms and their shared sub-trees encode and decode. It is engine-integrated and selectable on a live session: a peer pair negotiates it, and the handshake plus all subsequent traffic ride it through the codec-dispatch seam (`session.codec`), with the session state machine staying codec-neutral.

## Scope (what this does not decide)

- The Goblins-canonical GC and abort wire shapes — [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md).
- Handoff crypto and three-party protocol — [ADR-0009](ADR-0009-three-party-handoff-substrate.md).
- The `op:start-session` substrate and bootstrap-fetch shape — [ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md).
- Codec/feature selection at handshake time — [ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md) and [`src/ocapn/engine/negotiation.zig`](../../../src/ocapn/engine/negotiation.zig).

## Alternatives Considered

- **One global posture for every codec.** Rejected: forcing the Cap'n Proto slot to track Goblins shapes makes a pancake↔pancake session pay compatibility overhead it has no reader for; forcing Syrup ahead of spec text breaks it as the interop path.
- **Carry `CaptpVersion` on a codec instance.** Rejected: version becomes constructor-pinned and version dispatch leaks into instance state. The per-call `WireProfile` keeps codec functions stateless and makes the V1.0 gate a profile check.
- **Let feature negotiation pick the wire posture.** Rejected: profile, codec, and feature selection are separate axes. Collapsing them would hide the difference between OCapN semantics and serialization.

## Consequences

- Codec functions are stateless; the per-call `WireProfile` is the only version-bearing surface.
- A pancake-to-Goblins session sends `"1.0"` over Syrup. A pancake-to-pancake session can negotiate `v1_0` or `pre_spec`, and Syrup or Cap'n Proto where supported.
- **Symmetric refusal:** if a codec cannot represent a value, it fails loud (`Error.UnsupportedArgument` and siblings) rather than dropping it, so the model stays the single source of representability. The live example is a wire value with no model home (`Null`/`Dict`/`Float32` fidelity/bignum, ADR-0021): it is refused on decode rather than mis-decoded or silently coerced. A codec that cannot render a value the model *does* admit refuses the same way.
- Wire-profile work is validated against checked Goblins Syrup byte fixtures (`zig build oracle-check`), not byte-equality between codecs.

## Cross-codec parity

The Cap'n Proto codec fills the second-codec seam, so cross-codec semantic parity is backed rather than aspirational: the deliver/resolve and bootstrap-fetch conformance scenarios produce identical observable traces on Syrup and Cap'n Proto. The two wire encodings differ, but the observable behavior does not. Authenticated `op:start-session` verification uses the profile-level canonical `<my-location …>` signing input, so Cap'n Proto sessions do not get a weaker handshake path.

## Notes

[ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) settles the Goblins-canonical GC/abort shapes inside the `v1_0` profile. [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) and [ADR-0010](ADR-0010-payload-descriptor-discriminator.md) widen the model the codecs render; both are additive and bump no profile name.
