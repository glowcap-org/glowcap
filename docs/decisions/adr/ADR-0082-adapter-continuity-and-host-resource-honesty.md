---
id: ADR-0082
status: accepted
date: 2026-07-15
tags: [resilience, driver, net, host, configuration]
decision: "Adapter continuity and Host resource honesty live above CapTP: driver.DialRetry applies DialError-classified retry policy to caller-supplied complete dial attempts, whose success creates a new CapTP session. Host projects full SessionLimits. The completion loop may fan-in-throttle and park-kill. durable_bootstrap is a named Host posture, not CapTP wire replay."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0113, ADR-0124, ADR-0143, ADR-0193, ADR-0211]
---

# ADR-0082 Adapter continuity and Host resource honesty

## Context

[ADR-0081](ADR-0081-adapter-resilience-posture.md) provides the typed
`DialError` axis, bounded handshake/settle waits, keepalive, and dead-peer
reclaim, and reserves a continuity helper for retry and connection rebuild above
the loop. iroh discovery dial budgets are hand-copied across four bindings
(3s×24) and the Zig reachability driver (5s×12). `Host.Options` projects only
`frame_cap` into `SessionLimits.max_frame_bytes`, leaving the rest of the limit
struct unreachable at the Host mint. Fan-in backpressure and park-duration kill
are gaps under [ADR-0076](ADR-0076-loop-fed-host-bridge.md) and
[ADR-0042](ADR-0042-outbound-high-water-backpressure.md). Bootstrap registries
are process-lifetime with no named durability posture.

## Decision

1. **`driver.DialRetry` is the retry-policy executor.** It owns dial policy
   (attempt budget, retry interval), classifies `net.netlayer.DialError` into
   transient vs permanent, and retries only transient faults by invoking a
   caller-supplied complete dial attempt. The caller's attempt rebuilds the
   connection plus CapTP handshake, so success yields a new session identity.
   It is not a Session facade that preserves Peer tables across reconnect. Discovery dial
   budgets across bindings and Zig interop consume this one policy (default
   3000 ms × 24 attempts). CapTP application heartbeats stay refused until a
   measured keepalive miss demands them.

2. **Host resource honesty.** `Host.Options` carries `limits: session.SessionLimits`
   (admission `max_frame_bytes` replaces a parallel `frame_cap` field at the Zig
   Host). Minted peers receive the full configured limits and retain their own
   outbound high-water, so changing Host defaults affects only later sessions.
   Retryable application producers and inbound dispatch refuse before mutation
   while encoded outbound is at that mark. GC, close, and other reclamation
   traffic remain admissible. Selective C ABI knobs expose operator-useful fields.

3. **Loop overload controls.** Beyond per-connection ADR-0042 park, the
   completion loop offers fan-in source throttle (when a sink is parked, sources
   slow) and an optional park-duration kill that closes a connection that stays
   parked past a typed deadline.

4. **Layered Options.** Loop, Host, Session, SessionLimits, and Bridge Options
   share one vocabulary and are not merged into one struct.

5. **`durable_bootstrap` posture (fail-closed).** Host bootstrap/sturdyref
   registry durability is either `ephemeral` (process-lifetime) or
   `durable_bootstrap` (registry survives Host process restart under an
   embedder-supplied store). Identity netlayers (keyed-tcp, iroh) carry durable
   designators, and this posture covers the registry. Until a store is wired,
   `Host.init` refuses `.durable_bootstrap` with `DurableBootstrapUnavailable`
   before publishing a Host, so the arm cannot silently behave as ephemeral. The
   embedder decides whether that initialization failure ends its process. It is
   neither CapTP message replay, a Kafka commit log, nor SwingSet orthogonal
   persistence in the engine.

## Scope (what this does not decide)

- CapTP wire replay, pub/sub subjects, or broker clustering.
- Reconnect inside `completion.Loop` or the sans-io core (rejected by ADR-0081).
- CapTP application heartbeat as a shipped deliverable.
- Full orthogonal vat persistence (ADR-0060 remains local time-travel).
- Merging unlike Options structs into one type.

## Alternatives Considered

- **Separate public `dialWithRetry` beside `DialRetry`.** Rejected: the type's
  `dial` method is the policy executor.
- **Session facade that reconnects invisibly.** Rejected: CapTP peer tables do
  not survive dial loss, and hiding that is protocol fiction.
- **Options megastruct.** Rejected: it fights layer ownership (I/O vs CapTP vs session
  authority).
- **CapTP-level JetStream / Kafka log.** Rejected: durability belongs at Host
  bootstrap posture only.

## Consequences

- `src/driver/dial_retry.zig` holds the executor and `driver.mod` re-exports
  it.
- Discovery attempt/interval constants in bindings and
  `interop/iroh_reachability` align on the executor's default policy (or import
  generated/shared values).
- `Host.Options.limits` replaces Host-only `frame_cap`. C ABI keeps
  `frame_cap` as the admission field mapped into limits. Selective changes use
  the versioned `GlowcapSessionLimitOptions` record from ADR-0124 rather than
  positional integer arguments.
- `completion.Loop.Options` has fan-in, park-kill, and `on_park` fields.
  `on_park` carries a `ParkReason` because the two parks differ operationally:
  `.sink` is this connection's own partner failing to drain, `.fan_in` is this
  connection throttled for somebody else's. An embedder watching lag acts
  differently on each, they are indistinguishable from outside the loop, and the
  park is transient, so sampling loop state misses it. The N-to-1 fan-in
  behavioral test pins source park while a sink is held and source re-arm when
  the last sink drains. `DialRetry.on_dial_outcome` surfaces dial metrics.
- `Host.init` refuses `.durable_bootstrap` until an embedder store lands.
- Living-state docs (`boundaries.md`, architecture residual) point `DialRetry`
  and fan-in at this ADR.

## Forward compatibility

`durable_bootstrap` may grow an embedder store contract without changing CapTP
wire. Future transports project onto the same `DialError` axis the executor
classifies.

## Notes

Extends [ADR-0081](ADR-0081-adapter-resilience-posture.md). Builds on
[ADR-0076](ADR-0076-loop-fed-host-bridge.md) and
[ADR-0042](ADR-0042-outbound-high-water-backpressure.md).

## Appendix: inspiration to layers

| Source | Lesson | Where it lands |
|--------|--------|----------------|
| NATS Core | Minimize hot-path state, client reconnect, max_pending, write_deadline, config | DialRetry, Loop park / park-kill, layered Options |
| NATS JetStream *layering* | Durability *above* Core | `Host.BootstrapDurability`, not CapTP log |
| Kafka | Pull pacing, lag as health, durability as named tradeoff | Fan-in throttle, `on_park`, durable_bootstrap posture |
| Cap'n Proto RPC | Disconnect-aware rebuild. Sturdyref L2 ≈ Host durable registry | CapTP-honest session replacement. durable_bootstrap |
| SwingSet | Turn budget (have). Durable Host registry (want) | `local_turn_budget`. durable_bootstrap named |
| Goblins | Wire ceiling, never change for inspiration | Hard fence |
