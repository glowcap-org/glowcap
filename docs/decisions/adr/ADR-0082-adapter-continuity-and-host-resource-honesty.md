---
id: ADR-0082
status: accepted
date: 2026-07-15
tags: [resilience, driver, net, host, configuration]
decision: "Adapter continuity and Host resource honesty live above CapTP: driver.ResilientClient owns DialError-classified dial rebuild with CapTP-honest session replacement; Host projects full SessionLimits; the completion loop may fan-in-throttle and park-kill; durable_bootstrap is a named Host posture, not CapTP wire replay."
supersedes: []
superseded_by: []
---

# ADR-0082 Adapter continuity and Host resource honesty

## Context

[ADR-0081](ADR-0081-adapter-resilience-posture.md) shipped the typed `DialError`
axis, bounded handshake/settle waits, keepalive, and dead-peer reclaim. Its
forward-compat note reserved `driver.ResilientClient` for retry and endpoint
rebuild above the loop. That supervisor was still open; iroh discovery dial
budgets were hand-copied across four bindings (3s×24) and the Zig reachability
driver (5s×12); `Host.Options` projected only `frame_cap` into
`SessionLimits.max_frame_bytes` while the rest of the limit struct stayed
unreachable at the Host mint; fan-in backpressure and park-duration kill
remained named gaps under [ADR-0076](ADR-0076-loop-fed-host-bridge.md) and
[ADR-0042](ADR-0042-outbound-high-water-backpressure.md); bootstrap registries
stayed process-lifetime with no named durability posture.

This engages the First Principles that adapters own I/O and scheduling, that
production APIs make the correct path the easy path, and that CapTP semantics
stay codec-neutral and Goblins-compatible. Inspiration from NATS (client
reconnect, max_pending, write_deadline, JetStream *above* Core), Kafka (pull
pacing, lag as health, durability as a named tradeoff), Cap'n Proto RPC
(disconnect-aware rebuild, sturdyref level-2 survival), and SwingSet (turn
budgets, durable registry above the vat) maps onto adapter/Host layers only,
never onto the sans-io CapTP core.

## Decision

1. **`driver.ResilientClient` is the continuity core.** It owns dial policy
   (attempt budget, retry interval), classifies `net.netlayer.DialError` into
   transient vs permanent, retries only transient faults, and rebuilds dial plus
   CapTP handshake so the app sees a **new** session identity. It is not a
   Session facade that preserves Peer tables across reconnect. Discovery dial
   budgets across bindings and Zig interop consume this one policy (default
   3000 ms × 24 attempts). CapTP application heartbeats stay refused until a
   measured keepalive miss demands them.

2. **Host resource honesty.** `Host.Options` carries `limits: session.SessionLimits`
   (admission `max_frame_bytes` replaces a parallel `frame_cap` field at the Zig
   Host). Minted peers receive the full configured limits. Selective C ABI knobs
   expose operator-useful fields after the Zig path is honest.

3. **Loop overload controls.** Beyond per-connection ADR-0042 park, the
   completion loop offers fan-in source throttle (when a sink is parked, sources
   slow) and an optional park-duration kill that closes a connection that stays
   parked past a typed deadline.

4. **Layered Options stay layered.** Loop, Host, Session, SessionLimits, and
   Bridge Options are documented as one vocabulary with shared names; they are
   not merged into one mega-struct.

5. **`durable_bootstrap` posture (named, fail-closed).** Host
   bootstrap/sturdyref registry durability is either `ephemeral`
   (process-lifetime, today's live behavior) or `durable_bootstrap` (registry
   survives Host process restart under an embedder-supplied store). Identity
   netlayers (keyed-tcp, iroh) already carry durable designators; this posture
   is the registry catching up. Until a store is wired, `Host.init` refuses
   `.durable_bootstrap` with a panic so the arm cannot silently behave as
   ephemeral. It is not CapTP message replay, not a Kafka commit log, and not
   SwingSet orthogonal persistence in the engine.

## Scope (what this does not decide)

- CapTP wire replay, pub/sub subjects, or broker clustering.
- Reconnect inside `completion.Loop` or the sans-io core (rejected by ADR-0081).
- CapTP application heartbeat as a shipped deliverable.
- Full orthogonal vat persistence (ADR-0060 remains local time-travel).
- Merging unlike Options structs into one type.

## Alternatives Considered

- **Separate public `dialWithRetry` beside `ResilientClient`.** Rejected: one
  continuity core; the client *is* the policy owner.
- **Session facade that reconnects invisibly.** Rejected: CapTP peer tables do
  not survive dial loss; hiding that is protocol fiction.
- **Options megastruct.** Rejected: fights layer ownership (I/O vs CapTP vs
  session authority).
- **CapTP-level JetStream / Kafka log.** Rejected: wrong product; durability
  belongs at Host bootstrap posture only.

## Consequences

- `src/driver/resilient_client.zig` ships; `driver.mod` re-exports it.
- Discovery attempt/interval constants in bindings and
  `interop/iroh_reachability` align on the client's default policy (or import
  generated/shared values).
- `Host.Options.limits` replaces Host-only `frame_cap`; C ABI keeps
  `frame_cap` as the admission field mapped into limits, plus selective
  `pancake_host_set_session_limits` (`max_frame_bytes` / `queue_cap`).
- `completion.Loop.Options` grows fan-in, park-kill, and `on_park` fields;
  `on_park` carries a `ParkReason`, because the two parks are operationally
  different: `.sink` is this connection's own partner failing to drain,
  `.fan_in` is this connection throttled for somebody else's. An embedder
  watching lag cannot act on the two the same way, and from outside the loop
  they are indistinguishable — the park is transient, so sampling loop state
  misses it entirely;
  the N-to-1 fan-in behavioral test pins source park while a sink is held and
  source re-arm when the last sink drains. `ResilientClient.on_dial_outcome`
  surfaces dial metrics.
- `Host.init` refuses `.durable_bootstrap` until an embedder store lands.
- Living-state (`boundaries.md`, architecture residual) points
  `ResilientClient` and fan-in at this ADR, not a sibling plan.

## Forward compatibility

`durable_bootstrap` may grow an embedder store contract without changing CapTP
wire. Future transports project onto the same `DialError` axis the client
classifies.

## Notes

Extends [ADR-0081](ADR-0081-adapter-resilience-posture.md); builds on
[ADR-0076](ADR-0076-loop-fed-host-bridge.md) and
[ADR-0042](ADR-0042-outbound-high-water-backpressure.md).

## Appendix: inspiration to layers

| Source | Lesson | Where it lands |
|--------|--------|----------------|
| NATS Core | Minimize hot-path state; client reconnect; max_pending; write_deadline; config | ResilientClient; Loop park / park-kill; layered Options |
| NATS JetStream *layering* | Durability *above* Core | `Host.BootstrapDurability`, not CapTP log |
| Kafka | Pull pacing; lag as health; durability as named tradeoff | Fan-in throttle; `on_park`; durable_bootstrap posture |
| Cap'n Proto RPC | Disconnect-aware rebuild; sturdyref L2 ≈ Host durable registry | CapTP-honest session replacement; durable_bootstrap |
| SwingSet | Turn budget (have); durable Host registry (want) | `local_turn_budget`; durable_bootstrap named |
| Goblins | Wire ceiling, never change for inspiration | Hard fence |
