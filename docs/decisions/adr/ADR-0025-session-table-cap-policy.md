---
id: ADR-0025
status: accepted
date: 2026-05-17
tags: [session, limits, resilience, abort-taxonomy, security]
decision: Every partner-driven session accumulator is bounded by a configurable cap on the `SessionLimits` struct. A fresh insert past a cap fails loud with a typed `*CapExceeded` error that projects to a `resource_exhausted` `op:abort` and closes the session, never a silent drop. The five resource-exhaustion caps are `max_inbound_answers`, `max_listeners_per_target`, `max_imports`, `max_seen_handoff_counts`, and `max_deposited_gifts`; the sturdyref cache evicts instead of erroring and the local-delivery bound is an engine recursion guard.
supersedes: []
superseded_by: []
---

# ADR-0025 Session table-cap policy

## Context

A partner that completes `op:start-session` can grow pancake's session tables
without sending one malformed frame: blast `op:deliver` against ever-larger
answer ids, register listeners against one target, introduce fresh imports,
accumulate handoff-replay rows, or deposit gifts that are never withdrawn. None
violate a wire-shape invariant, so the decoder cannot catch them; left unbounded
they let a misbehaving peer exhaust host memory.

Session state is authoritative
([First Principles](../../../AGENTS.md#first-principles)), so the resource budget
belongs in the session, not deferred to an adapter that would have to
re-implement the state machine to enforce it. The policy makes the correct path
the easy path — a generous default the honest workload never sees — and fails
loud rather than absorb the overflow.

## Decision

Each partner-driven accumulator in
[`src/session/mod.zig`](../../../src/session/mod.zig) is bounded by a field on
`SessionLimits`. A fresh insert past the cap returns a typed `*CapExceeded`
error; refreshing an existing row never trips a cap. The five
resource-exhaustion caps each project to one wire kind, `resource_exhausted`:

| Cap | Default | Typed error |
| --- | ---: | --- |
| `max_inbound_answers` | 65 536 | `InboundAnswerCapExceeded` |
| `max_listeners_per_target` | 64 | `ListenerCapExceeded` |
| `max_imports` | 1 048 576 | `ImportCapExceeded` |
| `max_seen_handoff_counts` | 16 384 | `HandoffCountCapExceeded` |
| `max_deposited_gifts` | 65 536 | `DepositedGiftCapExceeded` |

`AbortKind.resource_exhausted` (`"ResourceExhausted"` on the wire) is a distinct
kind in [`src/model/mod.zig`](../../../src/model/mod.zig): the partner's traffic
is well-formed but exceeds the resource budget, so the observable contract ("back
off") differs from `protocol_error`. The projection in
[`src/engine/abort_projection.zig`](../../../src/engine/abort_projection.zig)
maps all five typed errors to a `resource_exhausted` abort with `close = true`;
the engine emits the abort before surfacing the typed error.

Two adjacent accumulators are bounded but do **not** project to
`resource_exhausted`, by design:

- `max_sturdyref_cache_entries` (default 256) bounds the dedup cache for
  resolved sturdyref enlivenments. The cache is non-load-bearing per
  [ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md) — a miss costs one
  extra bootstrap-fetch round-trip, not correctness — so an overflow evicts the
  oldest entry instead of erroring (a cap of 0 disables caching).
- `max_local_deliveries` (default 4096) is enforced by the engine's resolution
  drain, not a session table: it bounds the chain of local deliveries one
  resolution can trigger, failing with `LocalDeliveryCapExceeded` to stop a loop.

`queue_cap` (default 1024, the per-answer pipelined-call queue from
[ADR-0007](ADR-0007-promise-pipelining-substrate.md)) keeps its own
`QueueCapExceeded` → `queue_cap_exceeded` projection and is not folded into
`resource_exhausted`.

## Scope (what this does not decide)

- **Handoff-count expiry.** `max_seen_handoff_counts` defends against unbounded
  growth, but the replay-protection set cannot shrink without expiry semantics: a
  session that has seen handoff-count N must not be tricked into re-accepting it.
  The cap is the only defence; expiry rules are not settled here.
- **Outbound / pancake-allocated tables.** Export and outbound-answer tables grow
  at pancake's own rate, so they carry no cap. The caps bound partner-driven
  growth only.
- **Rate limiting.** A cap refuses a peer that pushes *past* it; a peer that
  churns rows at the cap is still admissible. Rate limiting belongs above pancake.
- **Per-deployment tuning.** Per-deployment tuning of the defaults is an adapter
  concern, not the session's.

## Alternatives Considered

- **Leave the accumulators unbounded.** Rejected: with no garbage collector a
  Zig deployment OOMs the host process; partner-driven growth must be bounded
  where the state lives.
- **Reuse `protocol_error` for the wire kind.** Rejected: a capped peer sends
  structurally-valid messages; `resource_exhausted` tells it to back off,
  `protocol_error` tells it to re-check its codec.
- **Per-cap wire kinds.** Rejected: the observable response is identical across
  the five ("back off"), so one kind plus the diagnostic message says the same
  thing without widening the wire contract.

## Consequences

- `SessionLimits` is the single tuning surface; table insert paths return typed
  `*CapExceeded` errors the engine projects to `resource_exhausted`.
- The `AbortKind` taxonomy (governed by
  [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md)) carries
  `resource_exhausted` as a public wire kind, distinct from `queue_cap_exceeded`
  and `handoff_replay`
  ([ADR-0009](ADR-0009-three-party-handoff-substrate.md)).
- Evidence: per-cap refusals in
  [`test/session/session_test.zig`](../../../test/session/session_test.zig), the
  five-error → `resource_exhausted` projection in
  [`test/engine/abort_projection_test.zig`](../../../test/engine/abort_projection_test.zig),
  and the Goblins-aligned `op_abort_resource_exhausted.bin` fixture asserted in
  [`test/codec/syrup_test.zig`](../../../test/codec/syrup_test.zig).

## Inbound nesting-depth cap

Inbound argument-tree nesting is bounded by `SessionLimits.max_nesting_depth`
(default 64). The recursive validate-and-install walk fails loud with
`NestingTooDeep`, projected to a `resource_exhausted` abort, instead of overflowing
the native stack. `view.toOwned` and `model.argumentsEqual` carry an independent
fixed depth ceiling as a model-layer backstop, so an over-nested tree is refused
even on the paths that do not run through session validation.

## Notes

- [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) owns the abort
  taxonomy this ADR extends; [ADR-0007](ADR-0007-promise-pipelining-substrate.md)
  owns `queue_cap`; [ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md)
  owns the sturdyref cache's non-load-bearing status.
