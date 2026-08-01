---
id: ADR-0041
status: accepted
date: 2026-06-10
tags: [net, runtime, c_abi, resilience, memory, performance]
decision: "Per-connection read buffers are small and fixed; an admissible inbound frame larger than the read buffer accumulates once in a bounded owned spill (`foundation.Spill`) and decodes from there, freed the moment it drains. All the inbound consumers (`pumpOver`, `readFrameFrom`/`FrameStream`, the completion loop, and the byte-fed host tier's stream tail) share the one spill type, each naming what a drained spill keeps, so steady per-connection memory is the read buffer, not `SessionLimits.max_frame_bytes`. Boundedness is the codec's cap-during-scan verdict (ADR-0029) plus a defensive incomplete-at-cap mirror in each consumer."
supersedes: []
superseded_by: []
---

# ADR-0041 Bounded inbound spill for small read buffers

## Context

ADR-0030 shipped the netlayer with a named slice-1 simplification: the read
buffer was sized to `max_frame_bytes` so any admissible frame framed whole from
the buffer. That couples steady per-connection memory to the largest frame a
session may ever accept: a 64 KiB cap costs 64 KiB per idle connection, which
the peer-scaling bench shows dominating the protocol core's per-connection state
by an order of magnitude. A many-connection server needs the read buffer to size
steady-state traffic, with the rare large frame paying its own way.

ADR-0030's scope named this follow-up (small-buffer + bounded-overflow) and
deferred it. This ADR closes it.

## Decision

**The read buffer sizes the steady state; the spill carries the rare large
frame.** `foundation.Spill` is a bounded owned accumulation that is inactive (zero
allocation) while frames fit the read buffer. When one frame outgrows the
buffer, the buffered prefix moves into the spill and the buffer keeps reading;
the frame decodes from the spill's contiguous bytes through the same one parser
(ADR-0029), and leftover bytes (the start of the next frame) compact forward.
A drained spill returns capacity past what its caller says to keep, and a
stream reader keeps nothing, so a burst of large frames shares one allocation
and a quiet connection holds none.

**Every inbound consumer shares the one type.** `pumpOver` (the peer-driving
connection), `readFrameFrom`/`FrameStream` (the peer-less frame boundary the C
ABI sits on), and the completion loop all hold a `foundation.Spill` and decode from
`spill bytes when active, read buffer
otherwise`. The stream-edge hand-off lives
in one shared function (`fillThroughSpill`), keeping the ADR-0030 property that
the consumers cannot disagree on a boundary. A clean EOF while the spill is
active is a mid-frame truncation, not a graceful close.

**Boundedness is the codec's verdict, mirrored defensively.** ADR-0029's
cap-during-scan contract means an `incomplete` verdict implies the scanned
prefix is under `max_frame_bytes`, so the spill never grows past the cap plus
one read buffer of unscanned tail. Each consumer keeps a defensive mirror: an
`incomplete` verdict over a prefix at or past the cap fails closed as
`FrameTooLarge`: so a codec regression cannot turn the spill into unbounded
buffering.

**The named costs.** The spill path costs one extra bounded copy per oversize
frame (read buffer into spill) and one allocation per oversize burst; the fast
path stays a zero-copy borrow with no allocation. Geometric growth bounds
realloc copies at twice the frame's bytes. These are recorded in the memory
rule's load-bearing list; the fast path is unchanged and the `alloc_budget`
floor still holds.

**Buffer sizing follows.** The C-ABI endpoint allocates
`min(max_frame_bytes, 16 KiB)` read buffers, the completion loop
`min(frame_cap, 16 KiB)`, and `Connection.initStream` documents a few KiB as the
production read-buffer shape. The write side already streamed large frames
through a small buffer (`writeAll`), so per-connection steady memory is now two
small buffers regardless of the negotiated cap.

## Scope (what this does not decide)

- **Full-duplex backpressure.** Unchanged from ADR-0030: a single fiber
  mid-`writeAll` to a slow reader can still head-of-line-block; split read/write
  fibers and a bounded outbound queue belong above `pump`.
- **Shared read-buffer pools / io_uring buffer rings.** The 16 KiB steady
  buffers are still per-connection; a provided-buffer ring that shares them
  across idle connections is the completion loop's named follow-up.
- **Codec semantics.** The one-parser contract and its verdicts are ADR-0029's;
  nothing here adds a second framer.

## Alternatives Considered

- **Keep whole-frame read buffers (slice 1).** Rejected: steady per-connection
  memory scales with `max_frame_bytes`, which the peer-scaling bench shows
  dwarfing the protocol core's per-connection cost.
- **Grow the read buffer in place.** Rejected: the reader's buffer is
  caller-owned and fixed by contract; growing it hides an allocation behind a
  buffer the caller thought they sized, and never shrinks back.
- **Retain spill capacity for the connection's lifetime.** Rejected: one large
  frame would pin `max_frame_bytes` of memory forever, recreating the problem
  the spill solves. What a drained spill keeps is the caller's to name, and a
  stream reader keeps nothing; a burst still shares one allocation. The
  byte-fed host tier names a small steady size instead, which is a different
  thing from pinning a burst: straddling a chunk boundary is its ordinary
  traffic rather than its exception.
- **Read directly into the spill once active.** Rejected for now: it would
  duplicate the stream-edge classification (`fillStep`) that
  graceful-vs-truncated EOF depends on, to save one bounded copy on the rare
  path.

## Consequences

- `foundation` gains `Spill`; `net` gains `fillThroughSpill` and the
  reader-shaped `absorbFrom` the core cannot hold; `pumpOver` and
  `readFrameFrom` take the caller's spill; `FrameStream.initStream` takes the allocator that
  owns its spill (and `readFrame` drops its allocator parameter so the two
  cannot diverge).
- The C-ABI endpoint and the completion loop allocate 16 KiB steady read
  buffers; `frame_cap` / `max_frame_bytes` cap a frame, not a buffer.
- Evidence: small-buffer assembly through the spill across both codecs
  (`test/net/frame_stream_test.zig`), pump-path spill carriage,
  truncation-while-spilling, and over-cap-while-spilling
  (`test/net/connection_test.zig`), and a real-socket keyed handshake through a
  64-byte client read buffer (`test/driver/blocking_session_test.zig`).

## Notes

- [ADR-0029](ADR-0029-one-parser-stream-framing.md) owns the cap-during-scan
  contract the boundedness leans on;
  [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md) owns the
  netlayer boundary and the `Connection` shape this fills in.
