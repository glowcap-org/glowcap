---
id: ADR-0029
status: accepted
date: 2026-06-05
tags: [codec, runtime, net, framing, resilience]
decision: "Stream frame boundaries are found by the active codec's own decoder (`decodePrefix`), not a separate length-prefix or delimiter scanner. The decoder distinguishes `incomplete` (need more bytes), `decoded` (whole frame + consumed length), `malformed` (structurally invalid), and `too_large` (would exceed `max_frame_bytes`). The engine (`recvStreamPrefix`) and the byte-stream adapter (`pumpOver`) consume that one verdict; there is no second parse."
supersedes: []
superseded_by: []
---

# ADR-0029 One-parser stream framing

## Context

A CapTP transport carries a stream of self-delimiting codec frames back to back.
The classic way to read them is two parsers: a framing scanner that finds the
boundary (a length prefix, or a delimiter scan), then the codec decoder that
parses the bounded slice. Two parsers means two notions of "where does this
frame end," which must agree on every byte: a permanent divergence surface, and
exactly the seam where a hostile partner finds a frame the scanner accepts but
the decoder rejects (or vice versa).

pancake's wire codecs are already self-delimiting: Syrup is length-prefixed and
fully recursive ([ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md)),
and the single-segment Cap'n Proto frame's length is computable from its header
([ADR-0026](ADR-0026-hand-rolled-capnp-codec.md)). The decoder already walks to
the end of a frame; the boundary is a byproduct of decoding, not separate
information.

## Decision

The codec decoder _is_ the framer. Each codec exposes
`decodePrefix(bytes, max_frame_bytes) -> framing.Prefix` over the buffered
stream prefix
([`src/ocapn/codec/framing.zig`](../../../src/ocapn/codec/framing.zig)):

- `decoded{ body, consumed }`: a whole frame is present; `consumed` is its
  exact byte length (the boundary), `body` the borrowed view.
- `incomplete`: a valid frame _prefix_; the caller must read more bytes.
- `malformed`: the bytes cannot begin a valid frame; fail loud.
- `too_large`: the in-flight frame's scanned length crosses `max_frame_bytes`
  _during_ decode, so a "never completes" stream is bounded without buffering it
  whole.

`incomplete` vs `malformed` is the load-bearing distinction and the one the leaf
readers must get right: truncation at the end of the buffer is `incomplete`
(read more), while a structurally impossible byte is `malformed` (reject).
Whole-frame entry points (`decodeBody`, `decodeView`) and re-parses of
already-bounded sub-slices (peer-key, signature) remap an inner `incomplete` to
`malformed`, because _within_ a bounded region "ran out of bytes" means the
region is corrupt, not that the stream needs more.

`codec.dispatch.decodePrefix` routes to the session's active codec. The engine
consumes exactly one verdict in `recvStreamPrefix` (`consumed` -> apply borrowed

- report length; `incomplete` -> ask for more; `malformed`/`too_large` -> typed
  error projected to `op:abort`), and the byte-stream adapter's `pumpOver`
  ([`src/net/connection.zig`](../../../src/net/connection.zig)) and peer-less
  `FrameStream`
  ([`src/net/frame_stream.zig`](../../../src/net/frame_stream.zig)) both
  `toss(consumed)` after a frame and `fillMore()` on `incomplete`. One parse,
  zero-copy apply, no separate boundary scanner anywhere.

Because the decoder recurses lazily over nested containers, decode-time
recursion is bounded by a fixed `max_decode_nesting` (512) in the Syrup decoder
so a deeply nested untrusted prefix is rejected as `malformed` before it can
overflow the native stack: the parse-stage analog of the session-level cap in
[ADR-0025](ADR-0025-session-table-cap-policy.md).

## Scope (what this does not decide)

- **Codec semantics.** `decodePrefix` is a framing entry point over the existing
  decoders; it changes no value-tree or message grammar.
- **Per-connection memory.** The buffer sizing and the bounded-overflow
  follow-up are [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md).
- **Abort projection.** Mapping `malformed` / `too_large` to abort kinds is
  owned by [`abort_projection`](../../../src/ocapn/engine/abort_projection.zig)
  / [ADR-0025](ADR-0025-session-table-cap-policy.md).

## Alternatives Considered

- **Length-prefix framing in the adapter.** Rejected: a second source of truth
  for frame length that must agree with the decoder on every byte; the
  divergence is a security seam, and Cap'n Proto / Syrup are already
  self-delimiting.
- **Delimiter scan.** Rejected: codec frames are binary with no reserved
  delimiter; a scan would re-encode codec knowledge outside the codec.
- **Decode the whole buffer eagerly.** Rejected: cannot distinguish "need more
  bytes" from "corrupt," which is precisely the stream-framing question.

## Consequences

- Each codec gains `decodePrefix`; `codec.dispatch` gains `decodePrefix` +
  `frameShape`; the Syrup error set gains `Incomplete` (internal to the decoder,
  never surfaced past a whole-frame boundary).
- `engine.Peer.recvStreamPrefix` is the single stream-framing entry the adapters
  drive.
- Evidence: the differential prefix-decode property test
  [`test/codec/prefix_decode_test.zig`](../../../test/codec/prefix_decode_test.zig)
  (incompleteness on every prefix, exact consumption, concatenation,
  malformation, oversize, and deep-nesting rejection) across both codecs.

## Notes

- [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) and
  [ADR-0026](ADR-0026-hand-rolled-capnp-codec.md) own the self-delimiting wire
  shapes this leans on; [ADR-0025](ADR-0025-session-table-cap-policy.md) owns
  the session-level nesting cap the decode-time bound mirrors.
