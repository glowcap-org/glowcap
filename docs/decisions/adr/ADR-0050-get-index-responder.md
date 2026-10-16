---
id: ADR-0050
status: accepted
date: 2026-06-11
tags: [engine, session, pipelining, get, index, goblins-interop]
decision: glowcap answers `op:get` / `op:index` (CapTP § Receiving): the projected answer is exported the moment the op lands, a projection row anchors on the receiver's answer, and the resolve seam drains it: resolving the projected answer to the Struct field or List element, following promise-shaped resolutions, or breaking. The initiator half installs the outbound answer on send. The field name is a Syrup String on the wire, matching the spec and live Goblins.
  supersedes: []
  superseded_by: []
amended_by: [ADR-0251]
---

# ADR-0050 The op:get / op:index responder

[ADR-0251](ADR-0251-next-operations-with-retained-crypto.md) limits these
wire projections to the `1.0` profile. Next rejects them.

## Context

ADR-0007 carried `op:get` / `op:index` through the model and codecs, but a
received op surfaced only an application event and glowcap never answered. The
spec's receive contract (CapTP § op:get) is: export a promise at
`new-answer-pos`, resolve it to the named field / element of the receiver's
eventual Struct / List, break on a missing field, an out-of-bounds index, a
non-container value, or a broken receiver, and follow intermediate promise
resolutions. Goblins implements this with a `hash-ref` / `list-ref` vow. Two
wire details needed fixing: glowcap encoded the field name as a Syrup Symbol
where the spec says String (and Goblins guards `string?` on receipt), and
sending an `op:get` did not install the outbound answer, so the partner's
resolve for it would have been refused as unknown.

## Decision

- **The session owns projection state.** A `Projection` row (field name or
  index, plus the projected answer position) hangs off the receiver answer's
  pipelining payload, like queued calls and listeners. The projection
  list shares the listener cap (`max_listeners_per_target`) and overflow is
  `ProjectionCapExceeded`, projecting to a `resource_exhausted` abort.
- **Apply exports the promise, and the engine anchors.** Receiving the op installs
  the inbound answer at `new-answer-pos` (the exported promise). The engine then
  anchors the projection on the receiver: a `desc:answer` names the answer
  directly. A `desc:export` position that is an inbound answer takes the same
  flip the listener install uses. Anything else can never settle to a value, so
  the projected answer breaks immediately.
- **The resolve seam drains projections.** When a sent `op:resolve` settles an
  answer, its projections drain beside the pipelined calls and listeners: each
  computes the field / element from the resolution
  (`engine.pipeline.projectResolution`, pure) and resolves its projected answer
  through the full send seam, so chained projections, pipelined calls, and
  listeners on the projected answer all settle in turn, and the V1.0
  translation applies unchanged (no resolver means the stored resolution feeds
  `op:listen`, which is how Goblins consumes it).
- **Indexes preserve OCapN Integer semantics.** An `op:index` operand is
  arbitrary-precision. A value too large or negative for any admitted List
  becomes an out-of-bounds projection marker. Its decimal wire bytes do not
  remain in session state.
- **No recursion, two bounds.** Encode deferral makes the drain iterative: a
  projected resolve is queued, not recursed, so projections-on-projections
  settle one step at a time and total work is bounded by what the caps admitted.
  The one synchronous walk, following stored resolutions that are themselves
  promises for a late op against a settled chain, is hop-bounded by
  `SessionLimits.max_resolution_chain`, so a cyclic stored-resolution chain
  breaks the projected answer instead of spinning.
- **The initiator half is symmetric.** Sending `op:get` / `op:index` validates
  the receiver like a deliver target and installs the projected answer outbound,
  so the partner's resolve admits.
- **The field name is a Syrup String** on the wire, per the spec and what live
  Goblins sends and guards. The Cap'n Proto codec already carried text.

## Scope (what this does not decide)

- `op:untag` ships on this substrate
  ([ADR-0052](ADR-0052-untag-responder.md)). Goblins still has no marshaller, so
  live proof is Zig scenarios and the upstream-encoder fixture.
- What the application resolves with is the application's: the engine projects
  whatever value the resolve carries.

## Consequences

- Field and element pipelining works on both sides, proven by the wire-driven
  engine scenarios (settle, late op, every break shape, the promise-following
  re-anchor, the cyclic-chain bound, the cap), and live as the asker: the
  `goblins-interop` gate pipelines an `op:index` / `op:get` against a Goblins
  vat and Goblins resolves the projection. The same gate proves Goblins-written
  `op:get` / `op:index` frames arrive at glowcap's responders and that glowcap
  settles both projected answers through V1.0 resolver-callback fulfillments.
  The probe bypasses a public Goblins application-level API for sending those
  projections because the pinned Goblins release has none.
- The get / index events still surface, so an application can observe the ops.
  The engine answers autonomously, and an application that races a manual
  resolve for a projected answer wins (the engine leaves a settled answer
  alone).
