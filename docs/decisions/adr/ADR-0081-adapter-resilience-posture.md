---
id: ADR-0081
status: accepted
date: 2026-07-14
tags: [resilience, net, driver, c-abi, error-handling]
decision: "The adapter layer fails closed with a typed reason a caller can act on: dial faults carry a transient/refused/unreachable/invalid axis, every blocking read on an untrusted partner is bounded, a vanished peer surfaces through on_close, and no path that settles protocol state swallows its error."
supersedes: []
superseded_by: []
amended_by: [ADR-0113, ADR-0184]
---

# ADR-0081 Adapter resilience posture

## Context

An adapter-layer audit found that the I/O surface hides the distinctions a
reconnecting or keyed peer must act on. A dial fault collapses to one opaque
reason on every transport: `socket_tcp` returns a single `SyscallFailed` for
bind, listen, and setsockopt (the kqueue sibling names each), and `tcp`,
`tcp_keyed`, `inproc`, and the iroh sidecar flatten refused, unreachable,
timeout, and a syntactically invalid address into one `ConnectionLost`. The
keyed handshake pump (`src/driver/session/connect.zig`) and its
`net.connection.runUntil` read with no deadline, so a peer that finishes
connect and then goes silent parks the calling thread for the connection's
life, a slowloris stall of a one-connection-per-thread `Server.accept` on
peer-controlled input. A remote that vanishes without a FIN leaves its armed
recv pending forever: the `completion.Loop` slot is never reclaimed and
`on_close` never fires under `run`. Several paths that settle protocol state
swallow their failure: the bridge redeem leg drops the only `dialFailed` a
ticket gets, the iroh completion bridge can consume a terminal dial without
publishing its sole completion, and the `c_abi/driver` release verbs return void
and degrade a projection failure to a generic `FAIL` with a stale `last_error`.

## Decision

The adapter layer (`net`, its transports, `driver`, `c_abi/driver`) guarantees a
caller can tell what failed and whether to retry. Four contracts:

1. **Typed dial reasons.** `net.netlayer.DialError` carries a
   transient/refused/unreachable/invalid-address axis, and every resident
   (`tcp`, `tcp_keyed`, `inproc`, iroh) projects its concrete fault onto it. The
   iroh sidecar returns a small distinct code set instead of a bare null, and
   the Linux `socket_tcp`/`uring` backend names bind/listen/socket/getsockname
   per operation as kqueue already does. A malformed direct-address hint is
   rejected as invalid before the network, and never surfaces as the
   transient-looking `ConnectionLost`.

2. **Bounded reads on untrusted partners.** `net.connection` exposes a
   bounded-read hook (a pump gated on `waitReadable(timeout_ms)` returning a
   typed `error.Timeout`). `driver.blocking_session` gates the handshake on an
   opt-in `handshake_timeout_ms` returning `Error.HandshakeTimedOut`. The
   deadline value is caller-supplied (policy lives above glowcap), and the net
   layer exposes the bounded hook.

3. **Liveness is surfaced.** A vanished or half-open peer is reclaimed during
   `run` and reported through `on_close`, not only at `closeAndDrain`, via a
   documented idle/dead-peer path or a conservative default keepalive. Opt-in
   keepalive either takes fully or reports that it did not, so no silent OS
   multi-hour default stays active under a configured window.

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

The sync no-I/O core fails closed with a typed reason, never blocks or times
out, and holds no socket. `arch-check`'s `core = true` I/O ban enforces this.

## Scope (what this does not decide)

- **Retry, backoff, and endpoint rebuild are not in the loop or the core.** They
  live above the completion loop in `driver` (see the sibling `DialRetry`
  work). The loop cannot own the endpoint it borrows, so full-endpoint rebuild is
  inherently a `driver`/consumer concern. This ADR only makes the loop surface
  the disconnect a supervisor rebuilds on.
- **Deadline and backoff values are not set here.** They are caller-supplied,
  per the resilience rule's "application deadlines belong above glowcap."
- The DM-by-introduction endpoint and any application reconnection policy are out
  of scope.

## Alternatives Considered

- **Per-site fixes without a contract.** Rejected: the divergence is the bug
  (Linux vs kqueue granularity, blocking vs readiness drain observability), so a
  new adapter would reintroduce it. The fix belongs at the netlayer/driver
  contract, so every resident and future backend inherits it.
- **Push timeouts/keepalive into the sync core.** Rejected: it violates the
  no-I/O core boundary.
- **Reconnect inside the completion loop.** Rejected: the loop borrows its
  backend and resident and cannot reconstruct them. Rebuild belongs one layer up.

## Consequences

- `net.netlayer.DialError` has the four-way axis. `tcp`, `tcp_keyed`, `inproc`,
  and the iroh `DialResolver` re-map onto the axis, and the bindings that read
  dial failures re-map with them.
- `net.connection` has a bounded-read hook. `driver.blocking_session`,
  `driver.Session`, and `driver.Server` take an optional handshake deadline.
- `completion.Loop` reclaims and reports a half-open slot under `run`.
- `c_abi/driver` records `last_error` on every degrade and gives the release
  verbs a status return.
- Gates: a `conformance/`-or-`interop/` scenario per transport pinning
  refused vs unreachable vs invalid-address. A `test/net` scenario pinning that a
  vanished peer's slot is reclaimed and `on_close` fires under `run`. A
  `test/driver` scenario pinning `HandshakeTimedOut` on a silent partner. A
  `test/c_abi` scenario pinning `last_error` is set and OOM is separable from a
  permanent failure on the degrade paths.

## Forward compatibility

The typed `DialError` axis is the seam `driver.DialRetry` branches on to
classify retry-worthy from fatal. That continuity core, Host-full `SessionLimits`,
fan-in throttle, park-kill, and the `durable_bootstrap` posture are decided in
[ADR-0082](ADR-0082-adapter-continuity-and-host-resource-honesty.md). The axis
is the vocabulary a future transport projects onto.

## Notes

Builds on the loop-fed host bridge (ADR-0076) and the keyed-tcp designator
(ADR-0075). The [resilience](../../../.agents/rules/resilience.md) and
[architecture](../../../.agents/rules/architecture.md) rules own the standing
layer-ownership map this record instantiates for error and liveness.
