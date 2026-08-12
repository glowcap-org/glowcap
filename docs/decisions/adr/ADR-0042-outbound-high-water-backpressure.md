---
id: ADR-0042
status: accepted
date: 2026-06-10
tags: [net, resilience, memory, performance]
decision: "The completion loop bounds each connection's outbound queue with a high-water mark: when pending outbound bytes cross it, the loop stops arming reads on that connection (no new inbound frames means no new replies) and resumes reading when the partner drains the queue. On drain, capacity past the fixed steady outbound bound is freed. The mark is independent resource policy: 64 KiB by default and replaceable loop-wide through `Options.outbound_high_water_bytes`."
supersedes: []
superseded_by: []
---

# ADR-0042 Outbound high-water backpressure in the completion loop

## Context

ADR-0041 bounded the inbound half of per-connection memory: read buffers size
the steady state and a rare large frame rides a bounded spill, freed on drain.
The outbound half had no such bound. The completion loop queues reply bytes in a
per-connection `ArrayList` while a write is in flight, and a partner that sends
requests without reading replies (a slow reader, deliberate or not) grew that
queue without limit. Worse, the queue retained its burst capacity for the
connection's lifetime (`clearRetainingCapacity`), so one slow-reader episode
pinned its high-water bytes per connection forever: the exact per-connection
scaling ADR-0041 removed on the read side.

The blocking pump has neither problem in memory terms (it writes synchronously
before reading), but a single fiber mid-`writeAll` to a slow reader still
head-of-line-blocks; that half of the seam is out of scope here and stays named
below.

## Decision

**Pending outbound past the high-water mark parks the read.** Replies are caused
by reads: a frame that is never read generates no reply. So the loop applies
backpressure at its cause: when a connection's pending outbound bytes cross the
mark, the loop stops arming reads on it instead of growing the queue. The
kernel's receive buffer fills, the partner's sends stall, and the flood stops at
the flooder. No protocol frame is dropped or reordered; the queue is bounded by
the mark plus the replies of frames already buffered when it crossed.

**The read resumes when the partner drains.** A fully drained write completes
the cycle: the loop re-arms the parked read, unless the drain itself queued past
the mark again (then the next drain re-checks). Park-at-mark, resume-at-drain is
deliberate hysteresis: a connection never thrashes between the two on a byte
boundary.

**Burst capacity frees on drain.** A drained queue whose capacity outgrew the
fixed steady outbound bound (`steady_outbound_bytes`) frees its storage rather
than retaining it, the same posture as the inbound spill: one burst must not
pin its peak for the connection's lifetime. Steady-sized capacity is retained
so ordinary reply traffic never reallocates. Read-pool sizing is independent.

**The mark is independent resource policy.** The 64 KiB default preserves the
original bounded-slack posture without pretending that this local session's
inbound admission limit says what its remote partner can receive. A frame may
cross the mark; the loop then parks further reads until the queued bytes drain.
`Options.outbound_high_water_bytes` replaces the default loop-wide for hosts
whose reply patterns want a different trade.

## Scope (what this does not decide)

- **The blocking pump's fiber split.** `pumpOver` remains a single fiber that
  can head-of-line-block mid-`writeAll`; split read/write fibers above the pump
  are the remaining half of the full-duplex seam (ADR-0030's deferral, settled
  as a refusal in [ADR-0053](ADR-0053-blocking-pump-single-fiber.md)).
- **Application rate limits and deadlines.** The initial decision leaves a
  parked connection holding bounded memory indefinitely; ADR-0082's amendment
  below adds the optional loop-owned deadline policy.
- **Shared read-buffer pools.** ADR-0054 owns pool count and buffer sizing;
  neither changes the outbound mark.

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

- `completion.Options.outbound_high_water_bytes` is a loop-wide resource
  control with a 64 KiB default. The loop's `Conn` gains a parked flag and the
  arm/park decision lives in one function the accept and recv paths share.
- Per-connection memory is now bounded in both directions: bounded spill only
  while a shared-pool frame is incomplete inbound (ADRs 0041 and 0054), steady
  queue plus high-water mark outbound (this ADR), both freeing burst storage on
  drain.
- Evidence: a scripted fake backend journals every submit and the test asserts
  the exact park/resume order: the send release strictly precedes the next
  armed read, twice (accept-time and mid-conversation): with no sockets and no
  timing, on every platform (`test/net/completion_loop_test.zig`).

## Notes

- [ADR-0041](ADR-0041-bounded-inbound-spill.md) is the inbound mirror;
  [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md) named the
  full-duplex deferral this closes the completion-loop half of.

## Amendment: fan-in throttle and park-kill (ADR-0082)

Per-connection park (this ADR) remains the default. Opt-in
`completion.Options.fan_in_throttle` additionally parks *source* reads
while any connection is a true sink park (outbound past high-water). Opt-in
`park_kill_ms` closes a connection that stays `.parked` past a monotonic
deadline, reported as `CloseReason.park_kill`.

A condemned connection's terminal flush is bounded separately, by
`drain_kill_ms`, and reported as `CloseReason.drain_kill`. That one is
finite by default: waiting for a partner to read an abort is teardown rather
than a policy about healthy slow readers, and no embedder should have to opt
in to avoid leaking a slot to a partner that never reads. The loop's poll
carries whichever deadline is nearest, so a quiet connection's deadline still
fires.

All of these live on the completion loop only; they do not change CapTP wire
or the sans-io core. See
[ADR-0082](ADR-0082-adapter-continuity-and-host-resource-honesty.md).
