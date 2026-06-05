---
id: ADR-0026
status: accepted
date: 2026-06-04
tags: [codec, capnp, wire-profile, zero-copy, view]
decision: The Cap'n Proto codec is hand-rolled in Zig against the wire format directly — no schema compiler, no generated code. It emits and accepts single-segment messages, defines struct/list layout in code, and decodes view-first (a borrowed `MessageView` over the frame bytes) so the codec honors the zero-copy projection contract before any op is grown in.
supersedes: []
superseded_by: []
---

# ADR-0026 Hand-rolled Cap'n Proto codec

## Context

[ADR-0003](ADR-0003-codec-interoperability-posture.md) reserved a Cap'n Proto slot as the second codec beside Syrup: codec neutrality (Invariant 1) and per-session codec selection are designed for it, and `negotiation.zig` already carries a `capnp` `CodecId`. Filling that slot needs a concrete strategy for *how* the codec reaches the wire.

Cap'n Proto is normally schema-driven: a `.capnp` schema compiled by `capnpc` into generated accessors. That toolchain is not present in this project's build — there is no `capnp` binary, no codegen step in [`build.zig`](../../../build.zig), and pulling one in would add a non-Zig build dependency and a generated-code surface to a codebase whose values put explicit, readable Zig first.

The wire format itself is small and fully specified: a message is a sequence of 8-byte little-endian words grouped into segments, and structured data is reached by following struct/list pointers that pack a signed word offset plus section sizes. Because Cap'n Proto here is the pancake↔pancake dialect (ADR-0003 § *spec-extending dialect*), the layout only has to be self-consistent between pancake peers — there is no third-party Cap'n Proto reader to satisfy, so a schema compiler buys nothing a hand-written layout does not.

Engages the First Principles *explicit over implicit* (the layout is readable Zig, not generated output) and *protocol correctness before convenience* (the codec honors the zero-copy contract from the first op, not as a retrofit).

## Decision

The Cap'n Proto codec ([`src/codec/capnp/`](../../../src/codec/capnp/)) is hand-rolled against the wire format. [`wire.zig`](../../../src/codec/capnp/wire.zig) is the mechanical substrate — segment framing, pointer bit-packing (`encodeStructPointer` / `encodeListPointer` and their decoders), a single-segment `Builder` that back-patches pointers, and a bounds-checked word `Reader`. [`core.zig`](../../../src/codec/capnp/core.zig) maps the codec-neutral [`model.Message`](../../../src/model/mod.zig) tree onto that substrate.

Three commitments fix the shape:

- **No schema compiler.** Struct and list layout is defined in code against `wire.zig`. The layout is pancake-internal and moves with the model; there is no generated module and no `.capnp` artifact.
- **Single segment.** The codec emits one segment and rejects multi-segment frames (`Error.UnsupportedSegmentCount`). pancake messages are small; multi-segment support is additive if a message ever needs it.
- **View-first decode (Invariant 3).** `decodeView` projects a borrowed `MessageView` over the frame's bytes, copying nothing; `decodeOwned` is `ownedFromView ∘ decodeView`, materializing only what the caller keeps. This mirrors the Syrup codec's `decodeView` / `ownedFromView` split, so the zero-copy contract holds from the first op rather than being bolted on later.

The envelope is a struct with a one-word data section holding a `Kind` union discriminant and a pointer section selecting the body struct. Every word read is bounds-checked against the segment; an empty struct or list legitimately points one word past the segment end, so pointer resolution rejects only indices strictly past the end and lets each read enforce its own bound. Malformed pointers, truncated frames, and unmapped discriminants fail loud rather than producing a partial value.

All ten `Message` arms and their shared sub-trees (`Reference`, the fourteen-arm recursive `Argument`, `Resolution`, `Error`, `PeerLocator`, `Handoff`, `Tagged`, `PipelineOp`) encode and decode view-first, exercised by round-trip and fail-loud tests in [`test/codec/capnp_test.zig`](../../../test/codec/capnp_test.zig). `BrokenRef` is local-only and rejected on encode (`Error.UnsupportedReference`).

### Live-session integration

The codec is selectable on a live session. `core.zig` also projects [`decodeBody`](../../../src/codec/capnp/core.zig) — the shared codec-neutral [`model.view.Body`](../../../src/model/view.zig) the runtime dispatches on — directly over the frame's words, the sibling of Syrup's `decodeBody`. The unbounded sequences (`Args`, `PositionList`, `PipelinePath`) are reached through the same inline vtable backings the neutral view defines, with the `Ctx` scalars packing each list's word layout (element-0 index, section sizes, count); a nested `list` / `set` / `tagged` arm is itself another backing, so the projection stays borrowed with no per-node allocation. `encodeMessageForProfile` is the encode counterpart (profile-independent: the schema always carries `resolve_me_desc` / `wants_partial`, and the runtime applies the V1.0 resolver-callback translation on the neutral model *before* encode, so that translation is codec-blind).

Selection routes through the codec-dispatch seam ([`codec.dispatch`](../../../src/codec/dispatch.zig)), a `switch` on the [`model.CodecId`](../../../src/model/mod.zig) the session records from `negotiation.Negotiated.chosen`. Because the set of codecs is closed (Syrup, Cap'n Proto) and known at compile time, the seam is an exhaustive tagged-union dispatch rather than a runtime vtable — zero indirection, and a third codec is a compile error until every seam handles it. The session state machine and the V1.0 translation never name a codec, so they stay codec-blind (Invariants 1, 12, 14); the only codec-aware surface is the seam.

## Scope (what this does not decide)

- **Cross-codec conformance.** A claim that Syrup and Cap'n Proto preserve the same semantic state machine across the whole scenario surface needs a conformance harness exercising both; the live-session parity tests in [`test/runtime/factories_test.zig`](../../../test/runtime/factories_test.zig) (handshake, deliver, and the V1.0 resolver-callback round-trip over Cap'n Proto) are the first such coverage, not the full matrix.
- **Real-crypto Cap'n Proto handshake.** `pairedWithKeys` signs the canonical `<my-location …>` bytes in Syrup (the signing input is profile-defined, not the session codec); a Cap'n Proto session uses the stub-key path today.

## Alternatives Considered

- **Add `capnpc` + a codegen step to the build.** Rejected: a non-Zig build dependency and a generated-code surface, to satisfy a schema-compiler contract no pancake↔pancake peer needs. The wire format is small enough to write directly.
- **Vendor an external Zig Cap'n Proto library.** Rejected: a maturity and maintenance dependency for a layer that is a few hundred lines of well-specified bit-packing, and that we want to keep moving with the model.
- **Owned decode first, view path later.** Rejected: Invariant 3 makes the borrowed projection the load-bearing shape. Building owned-first would write each op's mapping twice and risk an owned-shaped codec that the view path has to retrofit.

## Consequences

- The codec has no build-time tooling: `zig build test` compiles and exercises it like any other module.
- Decode is endian-explicit (`readInt(..., .little)`), so it is correct on any host, not only little-endian ones.
- Cap'n Proto frames are word-shaped ([`FrameShape.word`](../../../src/foundation/frame.zig)); the builder allocates word-aligned storage so the frame satisfies the shape's alignment invariant.
- Cap'n Proto carries typed values Syrup projects to strings (e.g. a typed `AbortKind` rather than Syrup's V1.0 abort wire string) — a concrete demonstration of codec neutrality (Invariant 1).
- The codec is both a standalone tested module (`pancake.codec.capnp`) and a live-session option negotiated per direct session (Invariant 4); a pair offering `capnp` runs its entire handshake and traffic over word-shaped frames.
- The codec-dispatch seam is the one place that names a codec. Adding a codec is: a `model.CodecId` arm, a `decodeBody` / `encodeMessageForProfile` pair, and two `switch` arms in `codec.dispatch` — the exhaustive switches flag every site that must grow.

## Notes

[ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the codec posture (codec-neutral model, per-call `WireProfile`, the reserved slot this ADR fills). The Syrup codec ([`src/codec/syrup/`](../../../src/codec/syrup/)) is the structural exemplar for the `decodeView` / `ownedFromView` split adopted here.
