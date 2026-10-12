---
id: ADR-0026
status: accepted
date: 2026-06-04
tags: [codec, capnp, wire-profile, zero-copy, view]
decision: The Cap'n Proto codec is hand-rolled in Zig against the wire format directly: no schema compiler, no generated code. It emits and accepts single-segment messages, defines struct/list layout in code, and decodes view-first (a borrowed `MessageView` over the frame bytes) so the codec honors the zero-copy projection contract before any op is grown in.
supersedes: []
superseded_by: []
---

# ADR-0026 Hand-rolled Cap'n Proto codec

## Context

[ADR-0003](ADR-0003-codec-interoperability-posture.md) reserved a Cap'n Proto
slot as the second codec beside Syrup, and `negotiation.zig` carries a `capnp`
`CodecId`. Filling that slot needs a strategy for how the codec reaches the
wire.

Cap'n Proto is normally schema-driven: a `.capnp` schema compiled by `capnpc`
into generated accessors. The project build has no `capnp` binary and no codegen
step in [`build.zig`](../../../build.zig). Adding one would add a non-Zig build
dependency and a generated-code surface.

The wire format itself is small and fully specified: a message is a sequence of
8-byte little-endian words grouped into segments, and structured data is reached
by following struct/list pointers that pack a signed word offset plus section
sizes. Cap'n Proto here is the glowcap-to-glowcap dialect (ADR-0003's glowcap-forward
/ `next` track), so the layout only has to be self-consistent between glowcap
peers. No third-party reader exists, so a schema compiler adds nothing over a
hand-written layout. Layout drift is
pinned by golden Cap'n Proto frames under
[`test/codec/capnp_fixtures/`](../../../test/codec/capnp_fixtures/) (regenerate
with `zig build gen-capnp-fixtures`). Discriminant sets stay locked at comptime
via `assertMirrorsMessageKinds` / `assertKindSetMatches`.

## Decision

The Cap'n Proto codec
([`src/ocapn/codec/capnp/`](../../../src/ocapn/codec/capnp/)) is hand-rolled
against the wire format. [`wire.zig`](../../../src/ocapn/codec/capnp/wire.zig)
is the mechanical substrate: segment framing, pointer bit-packing
(`encodeStructPointer` / `encodeListPointer` and their decoders), a
single-segment `Builder` that back-patches pointers, and a bounds-checked word
`Reader`. [`decode.zig`](../../../src/ocapn/codec/capnp/decode.zig) and
[`encode.zig`](../../../src/ocapn/codec/capnp/encode.zig) map the codec-neutral
[`model.Message`](../../../src/ocapn/model/mod.zig) tree onto that substrate.

Three commitments fix the shape:

- **No schema compiler.** Struct and list layout is defined in code against
  `wire.zig`. The layout is glowcap-internal and moves with the model. There is
  no generated module and no `.capnp` schema source. Golden frames under
  `test/codec/capnp_fixtures/` lock the bytes.
- **Single segment.** The codec emits one segment and rejects multi-segment
  frames (`Error.UnsupportedSegmentCount`). glowcap messages are small,
  and multi-segment support is additive.
- **View-first decode.** `decodeView` projects a borrowed `MessageView` over the
  frame's bytes, copying nothing. `decodeOwned` runs `decodeView` and then
  `ownedFromView`, materializing only what the caller keeps. This mirrors the
  Syrup codec's view-first decode (whose borrowed view is the codec-neutral
  `model.view.Body`, materialized through `toOwned`), so the zero-copy contract
  holds from the first op.

The envelope is a struct with a one-word data section holding a `Kind` union
discriminant and a pointer section selecting the body struct. Every word read is
bounds-checked against the segment. An empty struct or list points one word past the
segment end, so pointer resolution rejects only indices strictly past the end
and lets each read enforce its own bound. Malformed pointers, truncated frames,
and unmapped discriminants fail instead of producing a partial value.

All `Message` arms and their shared sub-trees (`Reference`, the fourteen-arm
recursive `Argument`, `Resolution`, `Error`, `PeerLocator`, `Handoff`, and
`Tagged`) encode and decode view-first, exercised by round-trip and
failure tests in
[`test/codec/capnp_test.zig`](../../../test/codec/capnp_test.zig). `BrokenRef`
is local-only and rejected on encode (`Error.UnsupportedReference`).

### Live-session integration

The codec is selectable on a live session. `decode.zig` also projects
[`decodeBody`](../../../src/ocapn/codec/capnp/decode.zig): the shared
codec-neutral [`model.view.Body`](../../../src/ocapn/model/view.zig) the engine
dispatches on: directly over the frame's words, the sibling of Syrup's
`decodeBody`. The unbounded sequences (`Args` and `PositionList`) are reached
through the same inline vtable backings the neutral view defines, with the `Ctx`
scalars packing each list's word layout (element-0 index, section sizes, count).
A nested `list` / `set` / `tagged` arm is itself another backing, so the
projection stays borrowed with no per-node allocation. `encodeMessageForProfile`
is the encode counterpart (profile-independent: the schema always carries
`resolve_me_desc` / `wants_partial`, and the engine applies the V1.0
resolver-callback translation on the neutral model before encode, so that
translation is codec-blind).

Selection routes through the codec-dispatch seam
([`codec.dispatch`](../../../src/ocapn/codec/dispatch.zig)), keyed on the
[`model.CodecId`](../../../src/ocapn/model/mod.zig) the session records from
`negotiation.Negotiated.codec`. Codecs resolve through an open comptime
registry (see the Open codec registry section below), so resolution unrolls at
compile time to zero-indirection dispatch while the codec set stays open to
consumer-supplied codecs. The session state machine and the V1.0 translation
never name a codec. The seam is the only codec-aware surface.

## Scope (what this does not decide)

- **Cross-codec parity.** Preserving the same semantic state machine
  across the whole scenario surface needs a scenario matrix exercising both
  codecs. The live-session parity tests in
  [`test/engine/pairing/offers_test.zig`](../../../test/engine/pairing/offers_test.zig)
  (authenticated handshake, deliver, and the V1.0 resolver-callback round-trip
  over Cap'n Proto) are the first such coverage, not the full matrix.

## Alternatives Considered

- **Add `capnpc` + a codegen step to the build.** Rejected: a non-Zig build
  dependency and a generated-code surface, to satisfy a schema-compiler contract
  no glowcap-to-glowcap peer needs. The wire format is small enough to write
  directly.
- **Vendor an external Zig Cap'n Proto library.** Rejected: a maintenance
  dependency for a layer that is a few hundred lines of well-specified
  bit-packing and moves with the model.
- **Owned decode first, view path later.** Rejected: the borrowed projection is the
  primary shape, and building owned-first would write each op's mapping twice.

## Consequences

- The codec has no build-time tooling: `zig build test` compiles and exercises
  it like any other module.
- Decode is endian-explicit (`readInt(..., .little)`), so it is correct on any
  host.
- Cap'n Proto frames are word-shaped
  ([`FrameShape.word`](../../../src/foundation/frame.zig)). The builder
  allocates word-aligned storage so the frame satisfies the shape's alignment
  invariant.
- Cap'n Proto carries typed values Syrup projects to strings (e.g. a typed
  `AbortKind` rather than Syrup's V1.0 abort wire string).
- The codec is both a standalone tested module (`glowcap.codec.capnp`) and a
  live-session option negotiated per direct session. A pair offering `capnp`
  runs its entire handshake and traffic over word-shaped frames.
- The codec-dispatch seam is the one place that names a codec. A built-in codec
  is a `model.CodecId` value, a `decodeBody` / `encodeMessageForProfile` pair,
  and a registry `Spec`. A consumer adds their own the same way by declaring
  `pub const glowcap_codecs` in their root (see the Open codec registry section
  below).

## Open codec registry

Codecs resolve through an open comptime registry keyed by a non-exhaustive
`model.CodecId`. The two built-ins, `syrup` and `capnp`, are the default set,
and a Zig consumer adds their own by declaring `pub const glowcap_codecs` in
their root source file. Resolution unrolls at `comptime`, so dispatch has no
indirection and the codec set stays open. "Bring your own codec" is a supported
contract.

## Notes

[ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the codec posture
(codec-neutral model, per-call `CaptpVersion`, the reserved slot this ADR fills).
The Syrup codec ([`src/ocapn/codec/syrup/`](../../../src/ocapn/codec/syrup/)) is
the structural exemplar for the view-first decode adopted here. Its borrowed
view is the codec-neutral `model.view.Body`.
