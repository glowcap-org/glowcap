---
id: ADR-0081
status: accepted
date: 2026-07-14
tags: [resilience, net, driver, c-abi, error-handling]
decision: "The adapter layer fails closed with a typed reason a caller can act on: dial faults carry a transient/refused/unreachable/invalid axis, every blocking read on an untrusted partner is bounded, a vanished peer surfaces through on_close, and no path that settles protocol state swallows its error."
supersedes: []
superseded_by: []
---

# ADR-0081 Adapter resilience posture

## Context

An adapter-layer audit found that pancake's I/O surface hides the very
distinctions a reconnecting or keyed peer must act on. A dial fault collapses to
one opaque reason on every transport: `socket_tcp` returns a single
`SyscallFailed` for bind, listen, and setsockopt (while the kqueue sibling
already names each), and `tcp`, `tcp_keyed`, `inproc`, and the iroh sidecar all
flatten refused, unreachable, timeout, and a syntactically invalid address into
one `ConnectionLost`. The keyed handshake pump
(`src/driver/blocking_session.zig`) and its `net.connection.runUntil` read with
no deadline, so a peer that finishes connect and then goes silent parks the
calling thread for the connection's life: a slowloris stall of a
one-connection-per-thread `Server.accept` on peer-controlled input. A remote
that vanishes without a FIN leaves its armed recv pending forever: the
`completion.Loop` slot is never reclaimed and `on_close` never fires under
`run`. And several paths that settle protocol state swallow their failure: the
bridge redeem leg drops the only `dialFailed` a ticket will ever get, the iroh
completion bridge could consume a terminal dial without publishing its sole
completion, and the `c_abi/driver` release verbs return void and degrade a
projection failure to a generic `FAIL` with a stale `last_error`.

This engages the First Principles that "protocol correctness and capability
semantics come before implementation convenience," that "the portable core stays
sync and no-I/O; adapters own `std.Io`, transports, scheduling," and that
"production APIs should make the correct path the easy path." It sits on the
netlayer and driver boundaries the [resilience rule](../../../.agents/rules/resilience.md)
governs: fail closed, surface typed reasons, keep policy at the owning layer.

## Decision

The adapter layer (`net`, its transports, `driver`, `c_abi/driver`) guarantees a
caller can always tell *what* failed and *whether to retry*. Four contracts:

1. **Typed dial reasons.** `net.netlayer.DialError` carries a
   transient/refused/unreachable/invalid-address axis, and every resident
   (`tcp`, `tcp_keyed`, `inproc`, iroh) projects its concrete fault onto it; the
   iroh sidecar returns a small distinct code set instead of a bare null, and
   the Linux `socket_tcp`/`uring` backend names bind/listen/socket/getsockname
   per operation as kqueue already does. A malformed direct-address hint is
   rejected as invalid *before* the network, not surfaced as the transient-looking
   `ConnectionLost`.

2. **Bounded reads on untrusted partners.** `net.connection` exposes a
   bounded-read hook (a pump gated on `waitReadable(timeout_ms)` returning a
   typed `error.Timeout`); `driver.blocking_session` gates the handshake on an
   opt-in `handshake_timeout_ms` returning `Error.HandshakeTimedOut`. The
   deadline *value* stays caller-supplied (policy lives above pancake) but the
   net layer owns exposing the bounded hook.

3. **Liveness is surfaced.** A vanished or half-open peer is reclaimed during
   `run` and reported through `on_close`, not only at `closeAndDrain`, via a
   documented idle/dead-peer path or a conservative default keepalive; opt-in
   keepalive either takes fully or reports that it did not (no silent OS
   multi-hour default left active under the appearance of a configured window).

4. **No silent state loss.** No path that settles protocol state: a dial
   ticket, a vow, a session release, a sibling flush: does `catch {}` without a
   recorded side channel. The `c_abi/driver` boundary records the real
   `@errorName` into `last_error` before any degrade, separates transient (OOM,
   resource pressure) from permanent (refused, malformed, unsupported), and
   makes the release verbs observable rather than void-swallowed.
   The iroh completion backend reserves the final synthetic fd and pending-dial
   row before sidecar admission. Before consuming readiness, it reserves enough
   completion-queue capacity for the batch, so consuming the sidecar's sole
   terminal result cannot be followed by an allocation failure that loses the
   corresponding Zig completion.

The sync no-I/O core keeps its existing posture unchanged: it fails closed with a
typed reason, never blocks, never times out, holds no socket; `arch-check`'s
`core = true` I/O ban is the enforcement, and this ADR adds nothing there.

## Scope (what this does not decide)

- **Retry, backoff, and endpoint rebuild are not in the loop or the core.** They
  live above the completion loop in `driver` (see the sibling `ResilientClient`
  work). The loop cannot own the endpoint it borrows, so full-endpoint rebuild is
  inherently a `driver`/consumer concern; this ADR only makes the loop *surface*
  the disconnect a supervisor rebuilds on.
- **Deadline and backoff *values* are not set here.** They stay caller-supplied,
  per the resilience rule's "application deadlines belong above pancake."
- The DM-by-introduction endpoint and any application reconnection policy are out
  of scope.

## Alternatives Considered

- **Per-site fixes without a contract.** Rejected: the divergence is itself the
  bug (Linux vs kqueue granularity, blocking vs readiness drain observability), so
  a new adapter would reintroduce it. The fix belongs at the netlayer/driver
  contract, once, so every resident and future backend inherits it.
- **Push timeouts/keepalive into the sync core.** Rejected: it violates the
  no-I/O core boundary the whole architecture rests on.
- **Reconnect inside the completion loop.** Rejected: the loop borrows its
  backend and resident and cannot reconstruct them; rebuild belongs one layer up.

## Consequences

- `net.netlayer.DialError` widens (the [prerelease posture](../../../.agents/rules/prerelease.md)
  permits it); `tcp`, `tcp_keyed`, `inproc`, and the iroh `DialResolver` re-map
  onto the axis, and the bindings that read dial failures re-map with them.
- `net.connection` grows a bounded-read hook; `driver.blocking_session`,
  `driver.Session`, and `driver.Server` gain an optional handshake deadline.
- `completion.Loop` reclaims and reports a half-open slot under `run`.
- `c_abi/driver` records `last_error` on every degrade and gives the release
  verbs a status return.
- New gates: a `conformance/`-or-`interop/` scenario per transport pinning
  refused vs unreachable vs invalid-address; a `test/net` scenario pinning that a
  vanished peer's slot is reclaimed and `on_close` fires under `run`; a
  `test/driver` scenario pinning `HandshakeTimedOut` on a silent partner; a
  `test/c_abi` scenario pinning `last_error` is set and OOM is separable from a
  permanent failure on the degrade paths.

## Forward compatibility

The typed `DialError` axis is the seam `driver.ResilientClient` branches on to
classify retry-worthy from fatal. That continuity core, Host-full `SessionLimits`,
fan-in throttle, park-kill, and the `durable_bootstrap` posture are decided in
[ADR-0082](ADR-0082-adapter-continuity-and-host-resource-honesty.md). The axis
remains the reserved vocabulary a future transport projects onto.

## Notes

Builds on the loop-fed host bridge (ADR-0076) and the keyed-tcp designator
(ADR-0075); the [resilience](../../../.agents/rules/resilience.md) and
[architecture](../../../.agents/rules/architecture.md) rules own the standing
layer-ownership map this record instantiates for error and liveness.
