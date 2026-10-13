---
id: ADR-0053
status: superseded
date: 2026-06-11
tags: [net, driver, runtime, resilience]
decision: "The blocking pump stays a single fiber by contract: its workload is cooperative request/response, where each side drains the replies it asked for. The read/write fiber split is refused, not pending (a second fiber over a single-threaded peer means a lock (a hidden runtime), and a bounded nonblocking write inside the pump means an fd-readiness dependency that breaks the type-erased transport contract and duplicates ADR-0042. Concurrent streaming and non-draining partners ride a completion loop) `net.TcpLoop` at the byte tier, or `completion.Loop(iroh.Backend, iroh.DialResolver)` over the sidecar (ADR-0057), both feeding `driver.Bridge` + Host (ADR-0076)."
supersedes: []
superseded_by: [ADR-0193]
---

# ADR-0053 The blocking pump stays one fiber. The loop is the duplex surface

> Superseded by [ADR-0193](ADR-0193-one-io-runtime.md): the blocking pump
> and `driver.BlockingSession` are deleted. Every Zig session runs on
> `driver.HostRuntime`'s completion loop, the duplex surface this ADR
> reserved for the loop.

## Context

ADR-0030 named the full-duplex deferral: a single fiber mid-`writeAll` to a
partner that is not reading can head-of-line-block, and two such pumps streaming
at each other can deadlock once both kernel buffers fill. ADR-0042 closed the
completion-loop half of that seam with a bounded outbound queue and read
parking. The blocking half, `net.Connection.pump` under `driver.BlockingSession`,
remained open. `engine.Peer` is single-threaded (no hidden runtime), and
`Connection` is type-erased over `std.Io.Reader` / `std.Io.Writer`, a contract
with no readiness signal. Every way to make one fiber duplex-safe breaks one of
those two invariants.

## Decision

**The split is refused.** The blocking pump's contract is cooperative
request/response: each side reads the replies its requests caused. Within that
contract one fiber cannot head-of-line-deadlock, by the causality ADR-0042 uses:
replies are caused by reads, and a caller blocking in `step` / `call` / `serve`
between requests is draining, not flooding. A
partner that streams without draining is outside the contract, and the surface
for that partner already exists: the completion loop bounds outbound bytes and
parks reads (ADR-0042), and both directions are packaged above it
(`net.TcpLoop`, ADR-0051, `iroh.Backend`, ADR-0057). glowcap has one duplex runtime.

## Scope (what this does not decide)

- **A write-stall deadline on the blocking pump.** A poll-`POLLOUT` deadline
  could convert an out-of-contract deadlock into a typed error, but deadlines
  are host policy above glowcap (resilience rule), and the mechanism would guard
  only callers the contract already routes to the loop.
- **The shared read-buffer ring and wall-clock checks.**
  [ADR-0054](ADR-0054-shared-read-buffer-ring.md) owns the ring, and
  [the performance milestone](../../ladder.md#2-performance-at-scale) records
  the checked latency budgets.

## Alternatives Considered

- **Split read/write fibers over one peer.** Rejected: two fibers sharing a
  single-threaded `engine.Peer` need a lock, which is a hidden runtime inside
  the portable surface.
- **A bounded nonblocking write inside the pump.** Rejected: readiness exists
  only at the fd, so the pump would fork into a tcp-only path beside the
  type-erased one and carry a second ADR-0042 implementation beside the loop's.
- **`BlockingSession` re-implemented over a one-connection completion loop.**
  Rejected: the loop multiplexes raw fds, so the in-process netlayer (ADR-0047)
  and any ADR-0043 resident would need the type-erased implementation anyway,
  leaving two diverging implementations under one API.

## Consequences

- `net.Connection.pump` documents the cooperative contract.
  `BlockingSession` is the transport-neutral blocking embedding.
- The ladder, README, and architecture doc state the contract split.
- The completion loop is the only place a non-draining partner is a supported
  workload, and its park/resume behavior stays pinned by
  `test/net/completion_loop_backpressure_test.zig`.

## Notes

- [ADR-0030](ADR-0030-netlayer-connection-and-memory-posture.md) named the
  deferral. [ADR-0042](ADR-0042-outbound-high-water-backpressure.md) decided the
  completion-loop half. This refuses the blocking half.
- [ADR-0051](ADR-0051-completion-loop-dialer.md) supplies the outbound loop
  packaging the contract routes streaming dialers to.
