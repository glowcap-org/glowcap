---
id: ADR-0053
status: accepted
date: 2026-06-11
tags: [net, driver, runtime, resilience]
decision: "The blocking pump stays a single fiber by contract: its workload is cooperative request/response, where each side drains the replies it asked for. The read/write fiber split is refused, not pending — a second fiber over a single-threaded peer means a lock (a hidden runtime), and a bounded nonblocking write inside the pump means an fd-readiness dependency that breaks the type-erased transport contract and duplicates ADR-0042. Concurrent streaming and non-draining partners ride the completion loop, which both directions package (LoopHost, LoopDialer)."
supersedes: []
superseded_by: []
---

# ADR-0053 The blocking pump stays one fiber; the loop is the duplex surface

## Context

ADR-0030 named the full-duplex deferral: a single fiber mid-`writeAll` to a
partner that is not reading can head-of-line-block, and two such pumps streaming
at each other can deadlock once both kernel buffers fill. ADR-0042 closed the
completion-loop half of that seam with a bounded outbound queue and read
parking. The blocking half — `net.Connection.pump` under `driver.ConnectedVat` —
remained open as a roadmap item, with the constraint already visible:
`engine.Peer` is single-threaded by design (no hidden runtime), and `Connection`
is type-erased over `std.Io.Reader` / `std.Io.Writer`, a contract with no
readiness signal. Every way to make one fiber duplex-safe has to pay one of
those two invariants.

## Decision

**The split is refused, not pending.** The blocking pump's contract is
cooperative request/response: each side reads the replies its own requests
caused. Within that contract one fiber cannot head-of-line-deadlock, by the same
causality ADR-0042 leans on — replies are caused by reads, and a caller blocking
in `step` / `call` / `serve` between requests is draining, not flooding. A
partner that streams without draining is outside the contract, and the surface
for that partner already exists: the completion loop bounds outbound bytes and
parks reads (ADR-0042), and both directions are packaged above it
(`driver.LoopHost`, `driver.LoopDialer`, ADR-0051). pancake deliberately has one
duplex runtime, not two.

## Scope (what this does not decide)

- **A write-stall deadline on the blocking pump is not implemented.** A
  poll-`POLLOUT` deadline could convert an out-of-contract deadlock into a typed
  error, but deadlines are host policy above pancake (resilience rule), and the
  mechanism would guard only callers the contract already routes to the loop.
- **The shared read-buffer ring and the wall-clock gate** are unchanged roadmap
  items.

## Alternatives Considered

- **Split read/write fibers over one peer**: rejected — two fibers sharing a
  single-threaded `engine.Peer` need a lock, which is a hidden runtime inside
  the portable surface.
- **A bounded nonblocking write inside the pump**: rejected — readiness exists
  only at the fd, so the pump would fork into a tcp-only path beside the
  type-erased one and carry a second ADR-0042 implementation beside the loop's.
- **`ConnectedVat` re-implemented over a one-connection completion loop**:
  rejected — the loop multiplexes raw fds, so the in-process netlayer (ADR-0047)
  and any ADR-0043 resident would need the type-erased implementation anyway,
  leaving two diverging implementations under one API.

## Consequences

- `net.Connection.pump` documents the cooperative contract instead of a
  deferral; `ConnectedVat` remains the transport-neutral blocking embedding.
- The roadmap's fiber-split item is settled by this refusal; the ladder, README,
  and architecture doc state the contract split rather than an open split.
- The completion loop is the only place a non-draining partner is a supported
  workload, and its park/resume behavior stays pinned by
  `test/net/completion_loop_test.zig`.

## Notes

- [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md) named the
  deferral; [ADR-0042](ADR-0042-outbound-high-water-backpressure.md) closed the
  completion-loop half; this closes the blocking half by refusing it.
- [ADR-0051](ADR-0051-completion-loop-dialer.md) supplies the outbound loop
  packaging the contract routes streaming dialers to.
