---
id: ADR-0003
status: accepted
date: 2026-04-30
tags: [codec, syrup, capnp, wire-profile, goblins-interop, captp-version]
decision: Codecs encode one codec-neutral model; codec functions are stateless across sessions and take a per-call `WireProfile` (a `CaptpVersion` plus opt-in `ProfileFlags`). Syrup advertises two profiles — pancake-internal `pre_spec` and Goblins-canonical `v1_0`. The Cap'n Proto slot is hand-rolled (ADR-0026) but not yet runtime-integrated.
supersedes: []
superseded_by: []
---

# ADR-0003 Codec and interoperability posture

## Context

pancake's semantics are codec-neutral: every type in [`src/model/mod.zig`](../../../src/model/mod.zig) carries the same meaning regardless of which codec rendered it. But a codec's *interoperability posture* — who it has to satisfy on the wire — is not neutral. Three regions, distinguished by what makes a shape legitimate:

- **Spec-faithful.** Bytes any OCapN peer following the spec accepts. Syrup at `CaptpVersion.v1_0` with the Goblins-canonical flag lives here: pancake encodes what the spec says and Goblins decodes it without knowing pancake exists.
- **Spec-extending dialect.** Shapes negotiated through mechanisms OCapN deliberately leaves open — the `acceptable-location.hints` map (`Locators.md` enumerates no keys). A Cap'n Proto encoding selected by a `pancake/codec` hint would live here.
- **Spec-anticipating.** Shapes from OCapN community consensus the spec text has not rendered yet. Syrup's `pre_spec` (`"pancake-pre-spec"`) profile lives here.

A second axis is where CapTP-version state lives. Pinning it to a codec instance ties version to construction; routing it per call keeps codec functions stateless and makes wire-profile dispatch a parameter, not a constructor flag.

Engages the First Principles *protocol correctness before convenience* and *session state is authoritative* (the codec renders; the session owns the profile it renders under).

## Decision

A [`WireProfile`](../../../src/model/mod.zig) — a `CaptpVersion` plus an opt-in `ProfileFlags` bitset — is a per-call parameter threaded into every encode/decode. Codec functions hold no cross-session state; the session caches the negotiated profile and supplies it.

The **Syrup** codec ([`src/codec/syrup/`](../../../src/codec/syrup/)) is the OCapN-compatibility codec. It translates between the codec-neutral `Message` model and the Syrup shapes Goblins-compatible traffic requires (resolver callbacks, split GC, handoff descriptors, error records). It advertises two profiles: `pre_spec` (pancake-internal) and `v1_0` with `goblins_canonical` (the OCapN-recognized wire). The `goblins_canonical` flag is the opt-in marker that selects the V1.0 translation path (resolver-callback `op:deliver` instead of `op:resolve`, split `op:gc-exports` instead of a single release).

The **Cap'n Proto** codec ([`src/codec/capnp/`](../../../src/codec/capnp/)) fills the second-codec slot, hand-rolled against the wire format per [ADR-0026](ADR-0026-hand-rolled-capnp-codec.md). It is view-first and codec-neutral, and complete: all ten `Message` arms and their shared sub-trees encode and decode. It is not yet runtime-integrated — the runtime's dispatch is bound to the Syrup view types and Goblins-v1.0 semantics — so the codec is reachable as a tested module rather than selectable on a live session. It advertises a single pancake-internal profile (`pre_spec`), because its wire shape does not vary with `CaptpVersion`.

## Scope (what this does not decide)

- The Goblins-canonical GC and abort wire shapes — [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md).
- Handoff crypto and three-party protocol — [ADR-0009](ADR-0009-three-party-handoff-substrate.md).
- The `op:start-session` substrate and bootstrap-fetch shape — [ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md).
- Codec/feature selection at handshake time — [ADR-0013](ADR-0013-cross-session-distributed-equality.md) and [`src/runtime/negotiation.zig`](../../../src/runtime/negotiation.zig).

## Alternatives Considered

- **One global posture for every codec.** Rejected: forcing the Cap'n Proto slot to track Goblins shapes makes a pancake↔pancake session pay compatibility overhead it has no reader for; forcing Syrup ahead of spec text breaks it as the interop path.
- **Carry `CaptpVersion` on a codec instance.** Rejected: version becomes constructor-pinned and version dispatch leaks into instance state. The per-call `WireProfile` keeps codec functions stateless and makes the V1.0 gate a flag check.
- **Let feature negotiation pick the wire posture.** Rejected: codec selection already owns the wire representation; a second axis would leak codec concerns into negotiation.

## Consequences

- Codec functions are stateless; the per-call `WireProfile` is the only version-bearing surface.
- A pancake↔pancake session sends `"pancake-pre-spec"` in `op:start-session`; a pancake↔Goblins session sends `"1.0"`.
- **Symmetric refusal:** if a codec cannot encode a value the model admits, it fails loud (`Error.UnsupportedArgument` and siblings) rather than dropping it, so the model stays the single source of representability. The Syrup `float64` encode gap is the live example — it returns `UnsupportedArgument`, asserted by a fixture, rather than silently omitting the argument.
- Wire-profile work is validated against checked Goblins Syrup byte fixtures (`zig build oracle-check`), not byte-equality between codecs.

## Forward compatibility

The reserved Cap'n Proto slot is the only second-codec seam. Adding it is additive: a new `CodecId`, a profile advertisement, and the view types the runtime would project. Until then, any claim of cross-codec semantic parity is unbacked — the conformance harness exercises one codec.

## Notes

[ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) settles the Goblins-canonical GC/abort shapes inside the `v1_0` profile. [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) and [ADR-0023](ADR-0023-nearref-kind-on-the-wire.md) widen the model the codecs render; both are additive and bump no profile name.
