---
id: ADR-0110
status: accepted
date: 2026-08-06
tags: [codec, runtime, net, framing, resilience, interop]
decision: "A byte-stream netlayer carries each bare codec frame inside one canonical Syrup byte string: decimal byte length, colon, then the frame bytes. Intrinsically message-framed transports and whole-frame APIs keep bare frames. The outer length owns the stream boundary; the negotiated codec must accept the complete body as exactly one frame."
supersedes: [ADR-0029]
superseded_by: []
amends: [ADR-0030, ADR-0072, ADR-0089, ADR-0090]
amended_by: []
---

# ADR-0110 Byte streams carry message envelopes

## Context

OCapN messages need a boundary independent of their negotiated inner codec.
Current Goblins byte-stream netlayers encode each complete message to bytes,
then write those bytes as a Syrup ByteArray. On the wire this is a canonical
decimal byte length, `:`, and that many body bytes. There is no netstring comma.

glowcap instead concatenated bare Syrup or Cap'n Proto frames and asked the
inner codec to find each boundary. That was internally self-consistent, but it
did not match the production Goblins transport.

The distinction belongs to the transport shape. TCP, in-process pipes, iroh
QUIC streams, onion streams, and similar adapters need the outer envelope.
WebRTC DataChannel messages and other transports that already preserve message
boundaries hand a complete bare frame to the whole-frame API.

## Decision

Every byte-stream adapter reads and writes one outer Syrup ByteArray per CapTP
message. The declared body length is checked against the session frame cap
before the body is allowed to accumulate. Empty, non-decimal, overflowing, and
non-canonical lengths are refused. EOF after any prefix or body byte is a
truncated frame; EOF between envelopes is a clean close.

The outer length is the stream-boundary authority. Once its body is complete,
the codec must validate the entire body as exactly one frame. A peer-less
`FrameStream` knows the codec but not the negotiated CapTP profile, so its
`framePrefix` returns only the structural boundary and accepts the union of
that codec's profile grammars. It never projects a semantic body: for example,
Cap'n Proto listen mode 1 has different meanings in V1.0 and next. The session
later decodes those same bytes under its negotiated profile. An incomplete
inner value, trailing second value, malformed value, or wrong frame shape is a
malformed frame. This preserves the codec validation from ADR-0029 without
making codec recursion the transport delimiter or inventing profile authority
in the transport.

Outbound adapters render the short length prefix on the stack and write the
prefix and borrowed frame body separately. Queue-backed completion loops reserve
space once, then append both slices. No intermediate envelope allocation or
body copy is added.

Whole-frame entry points remain bare. `Host.feed`, the C whole-frame API, and
intrinsically message-framed transports receive one codec frame with its shape.
Byte-stream entry points own outer-envelope tails across reads and unwrap before
calling the same whole-frame path. Outbound whole-frame drains also remain bare;
the byte-stream pump that writes them adds the envelope.

## Consequences

- Every byte-stream product front emits the same bytes as Goblins.
- Inner codecs no longer decide transport boundaries, but still reject a body
  that is not exactly one valid frame.
- Peer-less framing returns no semantic body; profile-aware session decoding is
  the only authority on profile-dependent message meaning.
- A negotiated codec can change without changing the byte-stream envelope.
- Frame caps cover the declared body. Steady read buffers remain smaller than
  the cap and use the existing bounded spill only when a body straddles reads.
- Message-framed transports do not pay for or expose a redundant envelope.

## Evidence

- Frame-stream tests pin the exact Goblins bytes, one-byte-at-a-time reads,
  coalesced envelopes, malformed and oversized lengths, truncated bodies, and
  rejection of multiple inner frames in one envelope.
- Connection, completion-loop, and owning-host tests cover both directions,
  high-water accounting, close behavior, and handshake pauses.
- C ABI and binding pump tests cover the byte-stream form while whole-frame
  tests keep bare-frame behavior explicit.

## Alternatives considered

**Keep concatenated bare codec frames.** Rejected because production Goblins
now uses the outer message envelope.

**Add the envelope to every transport.** Rejected because a transport that
already preserves messages has no stream-boundary problem to solve.

**Trust the outer length without decoding the whole body.** Rejected because
the envelope establishes only a byte boundary. The negotiated codec still owns
message grammar and frame shape.
