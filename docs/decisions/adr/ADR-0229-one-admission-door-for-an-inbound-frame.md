---
id: ADR-0229
status: accepted
date: 2026-10-14
tags: [codec, engine, net, framing, performance]
decision: "An inbound frame enters a session through one door. The byte-stream envelope or the transport's own message boundary delimits it, the engine copies it once behind a frame head, and the session parses it once into that head. No codec frames a stream, and no parse is moved after the fact."
supersedes: []
superseded_by: []
amends: [ADR-0030, ADR-0110, ADR-0222]
amended_by: []
---

# ADR-0229 One admission door for an inbound frame

## Context

This record completes a pivot ADR-0110 began. ADR-0029 made the codec the
stream framer: a resumable scan walked a partial Syrup frame across reads,
`decodePrefix` found each boundary, and a frame cap threaded through every
reader let the walk refuse mid-parse. ADR-0110 moved the boundary to the
envelope but kept all of that machinery as a validator of the envelope's
body, so the engine had two ways to admit a frame. The completion loops, the
blocking pump, and the C ABI transports read the envelope, copied its body
once behind the frame head, and parsed it once into that head, where the
argument list's views live (ADR-0222). The second entry parsed a frame on
the transport's borrowed buffer first and then moved the parse onto the
retained copy, and ADR-0222 built its slab around both entries. Behind the
second entry sat the scanner, a per-codec `self_delimiting` declaration the
registry checked, the threaded cap, and a source check whose only job was to
keep that module private.

Since ADR-0110 every byte-stream netlayer, Goblins included, carries each
frame in an envelope, so the inner codec never finds a boundary in
production. A grep of callers showed the second entry reached only from
tests and one test support file. The blocking pump still walked every frame
twice, once structurally to find its end inside a body whose end the
envelope had already declared, and once at admission. The webrtc packet door
parsed with no room lent for views and then moved its parse. Profiling a
`tcp` call round trip with callgrind showed the slab of ADR-0222 live on the
production path and the second entry contributing nothing, because nothing
shipped ran it.

## Decision

Every production path is the same shape: find the frame's end from the
envelope's declared length or the transport's packet boundary, copy once into
one allocation that carries the parse in front of the bytes, parse once into
that head, and read views from there in the validator and the Vat.
`engine.Peer.recvBorrowed` is that door. `recvPacket` is `recvBorrowed` with
the codec's shape looked up, because a message-framed transport carries
exactly one bare frame per packet. `net.recvOuterPrefix` and
`net.drainWholeFrames` unwrap the envelope and call it. `net.readFrameFrom`
lifts the envelope's body whole for a caller that admits it later through
`feedOwned`, and does not walk it.

The envelope's declared length is checked against the frame cap before any
body byte accumulates, so a cap during the parse has nothing left to refuse.
A body that is not exactly one frame of the negotiated codec, a truncated
body, a body with trailing bytes, or a malformed body is refused by the
session's one parse at admission, with the same typed abort a decoder
refusal has always projected.

Deleted with the second entry: `codec/framing.zig` and the `framing` layer,
`Peer.stream_scan`, the `scanStream`, `framePrefix`, and `decodePrefix`
families on both codecs and on `codec.dispatch`, the `self_delimiting`
registry declaration, `model.view.rebase` and `Body.rebased`, the
`frame_scan_gate` source check, and the byte-position limit every Syrup
reader carried so the walk could refuse mid-parse, with the `FrameTooLarge`
member of the Syrup error set that only that limit returned. The frame cap
is checked once, on the envelope's declared length or the packet's size.

## Scope (what this does not decide)

The Vat still copies a delivered message's parsed arguments into owned values
for its turn. That copy is the next seam on the inbound path and is not this
decision's.

## Alternatives Considered

- **Keep both entries and wire the slab into the second one**: measured, and
  it moved nothing on the production path because the production path never
  ran it. Two mechanisms for one job, one of them unexercised, is the cost
  this project refuses.
- **Keep the resumable scanner for a future transport that carries bare
  concatenated frames**: no such transport exists, the draft and Goblins use
  the envelope, and the prerelease posture keeps no capability for a consumer
  that does not exist.
- **Parse before copying, so a refused frame is never copied**: parse before
  copy cannot beat copy before parse for valid traffic, which is all of it in
  steady state, and the refusal path stays bounded by the envelope cap either
  way.

## Consequences

- One admission door, exercised by every transport and by every test that
  drives a peer. A test that needs a stream feeds envelopes through
  `net.recvOuterPrefix` or `net.drainWholeFrames`.
- The blocking pump walks a frame once instead of twice, and a body it lifts
  that is not one frame fails at `feedOwned` rather than at the read.
- `Peer` is 16 bytes smaller, and the three deliberate purchases its budget
  names no longer include a scan.
- The webrtc packet door lends its head's room for argument views like every
  other door.
- The `tcp` round trip's instruction count did not change: three identical
  callgrind runs of the result sit within 128 instructions of the baseline,
  all of it the compiler inlining the Syrup decoder's core once it had one
  caller. The benchmarks page's recipe now states the floor those runs
  established.
- Evidence: `test/engine/completion_seam_test.zig` pins the envelope seam
  under arbitrary read boundaries, the cap on the declared length, the exact
  cap, and the refusal of a body that is not one frame.
  `test/codec/whole_frame_test.zig` pins that every strict prefix and every
  concatenation is a malformed frame on both codecs.
  `test/net/frame_stream_test.zig` pins the blocking pump, and
  `test/engine/parse_once_test.zig` pins that the event reads the retained
  frame and its head's views.
