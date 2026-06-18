---
id: ADR-0042
status: accepted
date: 2026-06-10
tags: [net, resilience, memory, performance]
decision: "The completion loop bounds each connection's outbound queue with a high-water mark: when pending outbound bytes cross it, the loop stops arming reads on that connection (no new inbound frames means no new replies) and resumes reading when the partner drains the queue. On drain, burst capacity past the steady read-buffer size is freed, mirroring the inbound spill's free-on-drain posture (ADR-0041). The mark defaults to `frame_cap` and is host-tunable via `Options.outbound_high_water`."
supersedes: []
superseded_by: []
---

# ADR-0042 Outbound high-water backpressure in the completion loop

## Context

ADR-0041 bounded the inbound half of per-connection memory: read buffers size
the steady state and a rare large frame rides a bounded spill, freed on drain.
The outbound half had no such bound. The completion loop queues reply bytes in a
per-connection `ArrayList` while a write is in flight, and a partner that sends
requests without reading replies — a slow reader, deliberate or not — grew that
queue without limit. Worse, the queue retained its burst capacity for the
connection's lifetime (`clearRetainingCapacity`), so one slow-reader episode
pinned its high-water bytes per connection forever — the exact per-connection
scaling ADR-0041 removed on the read side.

The blocking pump has neither problem in memory terms (it writes synchronously
before reading), but a single fiber mid-`writeAll` to a slow reader still
head-of-line-blocks; that half of the seam is out of scope here and stays named
below.

## Decision

**Pending outbound past the high-water mark parks the read.** Replies are caused
by reads: a frame that is never read generates no reply. So the loop applies
backpressure at its cause — when a connection's pending outbound bytes cross the
mark, the loop stops arming reads on it instead of growing the queue. The
kernel's receive buffer fills, the partner's sends stall, and the flood stops at
the flooder. No protocol frame is dropped or reordered; the queue is bounded by
the mark plus the replies of frames already buffered when it crossed.

**The read resumes when the partner drains.** A fully drained write completes
the cycle: the loop re-arms the parked read, unless the drain itself queued past
the mark again (then the next drain re-checks). Park-at-mark, resume-at-drain is
deliberate hysteresis — a connection never thrashes between the two on a byte
boundary.

**Burst capacity frees on drain.** A drained queue whose capacity outgrew the
steady read-buffer size (`loop_read_buf_bytes`) frees its storage rather than
retaining it, the same posture as the inbound spill: one burst must not pin its
peak for the connection's lifetime. Steady-sized capacity is retained so
ordinary reply traffic never reallocates.

**The mark defaults to the frame cap.** One largest-admissible frame of pending
replies is the natural unit of slack — symmetric with the inbound bound, and it
admits any single frame without parking on it. `Options.outbound_high_water`
overrides it for hosts whose reply patterns want a different trade.

## Scope (what this does not decide)

- **The blocking pump's fiber split.** `pumpOver` remains a single fiber that
  can head-of-line-block mid-`writeAll`; split read/write fibers above the pump
  are the remaining half of the full-duplex seam (ADR-0030's deferral, settled
  as a refusal in [ADR-0053](ADR-0053-blocking-pump-single-fiber.md)).
- **Application rate limits and deadlines.** A parked connection holds its
  bounded memory indefinitely if the partner never drains; killing it on a timer
  is host policy above pancake (resilience rule).
- **Shared read-buffer pools.** Unchanged from ADR-0041's named follow-up.

## Alternatives Considered

- **Cap the queue and error past it.** Rejected: outbound frames are protocol
  state already committed by the session (a resolve the partner is owed);
  dropping or failing them mid-session turns a slow reader into a protocol
  violation by _us_. Parking reads refuses new work instead of breaking promised
  work.
- **Resume below a separate low-water mark.** Rejected: resume-at-drain is
  already hysteresis, with one fewer knob; a partner that drains at all drains
  the whole in-flight write.
- **Always free the queue on drain.** Rejected: the queue drains on every reply
  round, so unconditional free would put an allocation on the steady-state wire
  path. Freeing only past the steady size keeps the hot path allocation-free and
  the idle state small.

## Consequences

- `completion.Options` gains `outbound_high_water` (`null` defaults to
  `frame_cap`); the loop's `Conn` gains a parked flag and the arm/park decision
  lives in one function the accept and recv paths share.
- Per-connection memory is now bounded in both directions: read buffer plus
  bounded spill inbound (ADR-0041), steady queue plus high-water mark outbound
  (this ADR), both freeing burst storage on drain.
- Evidence: a scripted fake backend journals every submit and the test asserts
  the exact park/resume order — the send release strictly precedes the next
  armed read, twice (accept-time and mid-conversation) — with no sockets and no
  timing, on every platform (`test/net/completion_loop_test.zig`).

## Notes

- [ADR-0041](ADR-0041-bounded-inbound-spill.md) is the inbound mirror;
  [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md) named the
  full-duplex deferral this closes the completion-loop half of.
