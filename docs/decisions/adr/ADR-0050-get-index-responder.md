---
id: ADR-0050
status: accepted
date: 2026-06-11
tags: [engine, session, pipelining, get, index, goblins-interop]
decision: pancake answers `op:get` / `op:index` (CapTP § Receiving): the projected answer is exported the moment the op lands, a projection row anchors on the receiver's answer, and the resolve seam drains it: resolving the projected answer to the Struct field or List element, following promise-shaped resolutions, or breaking. The initiator half installs the outbound answer on send. The field name is a Syrup String on the wire, matching the spec and live Goblins.
  supersedes: []
  superseded_by: []
---

# ADR-0050 The op:get / op:index responder

## Context

ADR-0007 carried `op:get` / `op:index` through the model and codecs but named
the responder a boundary: a received op surfaced an application event and
nothing more, so a peer could ask and pancake never answered: field and element
pipelining was half-built. The spec's receive contract (CapTP § op:get) is:
export a promise at `new-answer-pos`, resolve it to the named field / element of
the receiver's eventual Struct / List, break on a missing field, an
out-of-bounds index, a non-container value, or a broken receiver, and follow
intermediate promise resolutions. Goblins implements exactly this with a
`hash-ref` / `list-ref` vow. Two wire details surfaced while closing the
boundary: pancake encoded the field name as a Syrup Symbol where the spec says
String (and Goblins guards `string?` on receipt), and sending an `op:get` never
installed the outbound answer, so the partner's eventual resolve for it would
have been refused as unknown.

## Decision

- **The session owns projection state.** A `Projection` row (field name or
  index, plus the projected answer position) hangs off the receiver answer's
  pipelining payload, exactly like queued calls and listeners. The projection
  list shares the listener cap (`max_listeners_per_target`) and overflow is a
  loud `ProjectionCapExceeded`, projecting to a `resource_exhausted` abort.
- **Apply exports the promise; the engine anchors.** Receiving the op installs
  the inbound answer at `new-answer-pos` (the exported promise). The engine then
  anchors the projection on the receiver: a `desc:answer` names the answer
  directly; a `desc:export` position that is an inbound answer takes the same
  flip the listener install uses; anything else can never settle to a value, so
  the projected answer breaks immediately.
- **The resolve seam drains projections.** When a sent `op:resolve` settles an
  answer, its projections drain beside the pipelined calls and listeners: each
  computes the field / element from the resolution
  (`engine.pipeline.projectResolution`, pure) and resolves its projected answer
  through the full send seam: so chained projections, pipelined calls, and
  listeners on the _projected_ answer all settle in turn, and the V1.0
  translation applies unchanged (no resolver means the stored resolution feeds
  `op:listen`, which is how Goblins consumes it).
- **Indexes preserve OCapN Integer semantics.** An `op:index` operand is
  arbitrary-precision. A value too large or negative for any admitted List
  becomes an out-of-bounds projection marker; its decimal wire bytes do not
  remain in session state.
- **No recursion, two bounds.** Encode deferral makes the drain iterative: a
  projected resolve is _queued_, never recursed, so projections-on-projections
  settle one step at a time and total work is bounded by what the caps admitted.
  The one synchronous walk: following _stored_ resolutions that are themselves
  promises, for a late op against a settled chain: is hop-bounded by
  `SessionLimits.max_projection_chain`, so a cyclic stored-resolution chain
  breaks the projected answer instead of spinning.
- **The initiator half is symmetric.** Sending `op:get` / `op:index` validates
  the receiver like a deliver target and installs the projected answer outbound,
  so the partner's resolve admits.
- **The field name is a Syrup String** on the wire, per the spec and what live
  Goblins sends and guards. The Cap'n Proto codec already carried text.

## Scope (what this does not decide)

- `op:untag` ships on this substrate
  ([ADR-0052](ADR-0052-untag-responder.md)); Goblins still has no marshaller, so
  live proof is Zig scenarios and the upstream-encoder fixture.
- Goblins-side semantics of _what_ the application resolves with are the
  application's: the engine projects whatever value the resolve carries.

## Consequences

- Field and element pipelining is real on both sides. Proven by the wire-driven
  engine scenarios (settle, late op, every break shape, the promise-following
  re-anchor, the cyclic-chain bound, the cap), and live as the asker: the
  `goblins-interop` gate pipelines an `op:index` / `op:get` against a Goblins
  vat and Goblins resolves the projection. The same gate proves Goblins-written
  `op:get` / `op:index` frames arrive at pancake's responders and that pancake
  settles both projected answers through V1.0 resolver-callback fulfillments.
  The probe still bypasses a public Goblins application-level API for sending
  those projections because the pinned Goblins release does not expose one.
- The get / index events still surface, so an application can observe the ops;
  the engine answers autonomously, and an application that races a manual
  resolve for a projected answer simply wins (the engine leaves a settled answer
  alone).
