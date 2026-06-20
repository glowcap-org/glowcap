---
id: ADR-0007
status: accepted
date: 2026-05-04
tags: [pipelining, op-listen, queue, fifo-drain, syrup-decompose, listener-fire]
decision: A pipelined `op:deliver` against a still-pending inbound answer queues FIFO on that answer's entry and drains against the resolution (far-forward / local delivery / requeue) when the answer settles; `op:listen` installs a listener fired on resolve. A promise target carrying a non-empty pipeline path has no single-frame Syrup shape, so it decomposes at the sender into a chain of single-hop `op:deliver`s, each recorded and enqueued through the normal send path.
supersedes: []
superseded_by: []
---

# ADR-0007 Promise pipelining substrate

## Context

A caller can address an `op:deliver` at a promise — an answer the partner has
not resolved yet — instead of a settled capability. OCapN's wire target for that
case is `<desc:answer answer-pos>`, a single positive integer (CapTP
Specification.md § desc:answer): the descriptor carries no pipeline path, and
chained pipelining is chained `op:deliver` messages, not a multi-step path
embedded in one frame.
[`src/ocapn/model/mod.zig`](../../../src/ocapn/model/mod.zig) still models a
`PipelinePath` of `PipelineOp` steps on `PromiseRef`, because the path is
application-level structure the engine must carry even though Syrup has no
operand for it.

Two questions follow. Where does a call queued against an unresolved answer
live, and how does it drain when the answer settles? And how does a promise
target carrying a non-empty path reach the wire when the only implemented codec
— Syrup — has no path operand?

`op:listen` is the sibling operation: it installs a party to be told when an
answer resolves. The spec shape is `<op:listen to-desc listen-desc>`; Spritely
Goblins always emits a third `wants-partial?` operand
(`goblins/ocapn/captp.rkt`), which controls whether a listener fires at
intermediate promise hops or only on the settled value.

Engages the First Principles
[_session state is authoritative_](../../../AGENTS.md#first-principles) — queued
calls and listeners live in the session, not the engine — and _protocol
correctness before convenience_: every resource bound is a loud error, never a
silent drop.

## Decision

### Queue ownership and drain

The inbound answer table owns pipelining state.
[`AnswerEntry`](../../../src/ocapn/session/mod.zig) carries a FIFO `queue` of
owned `op:deliver` messages, a `listeners` list, and the stored `resolution`. An
inbound `op:deliver` whose target is a still-`pending` answer is held there
([`Session.enqueuePipelinedCall`](../../../src/ocapn/session/mod.zig)) and
surfaces no application event;
[`Peer.maybeEnqueuePipelinedCall`](../../../src/ocapn/engine/mod.zig) makes that
decision at dispatch time.

When a `Peer` sends `op:resolve` for that answer, `step` drains the queue
([`Peer.drainPipelinedCalls`](../../../src/ocapn/engine/mod.zig)) and then fires
the listeners — calls first, since a drained call may settle further answers.
Each queued call dispatches against the resolution
([`Peer.dispatchDrainedCall`](../../../src/ocapn/engine/mod.zig)): a `far`
resolution forwards the call on the wire (target rewritten via
[`pipeline.rewriteDeliverTarget`](../../../src/ocapn/engine/pipeline.zig)); a
`near` resolution delivers locally; another promise re-queues against it with
cycle detection; every other shape drops the call.

### Listener fire matrix

[`pipeline.classifyListenerDrain`](../../../src/ocapn/engine/pipeline.zig)
decides each listener's fate against the resolution and its `wants_partial`
flag. A `Fulfill(Promise(_))` resolution re-anchors the listener on the next
answer — firing the partial first only when `wants_partial` — while every other
resolution fires the listener once via
[`pipeline.synthesizeListenerFire`](../../../src/ocapn/engine/pipeline.zig),
which builds the resolver-method `op:deliver` (`[Symbol("fulfill"), payload]` or
`[Symbol("break"), <error>]`). Drain order is arrival order: FIFO matches
Goblins's promise-queue draining and the transitive forwarding the OCapN spec
describes (Model.md § Promise).

### Multi-hop decomposition at the sender

`desc:answer` carries no path operand, so a `Message.deliver` whose target is a
promise with a non-empty `PipelinePath` has no single-frame Syrup shape.
[`Peer.send`](../../../src/ocapn/engine/mod.zig) detects this
(`target == .promise` and `!path.isEmpty()`) and routes to
`sendDecomposedPipeline`, which calls
[`pipeline.decomposeOutboundDeliver`](../../../src/ocapn/engine/pipeline.zig):
each `call` step becomes its own flat `op:deliver` against a freshly allocated
intermediate answer, and the caller's outer deliver chains against the last.
Each link is recorded and enqueued through the same send path, so every
`desc:answer` that reaches the wire is flat and every queued inbound call
carries an empty path.

A `field` step has no `op:deliver` analog — OCapN is methodic, with no
structural-navigation shape — so the decomposer rejects it loudly with
`UnsupportedPipelineOp` rather than dropping a step.

### Bounds

[`SessionLimits`](../../../src/ocapn/session/mod.zig) caps each surface:
`queue_cap` per pending answer (`QueueCapExceeded`), `max_listeners_per_target`
(`ListenerCapExceeded`), `max_inbound_answers`, and `max_local_deliveries` for
the chain of local deliveries one resolution can trigger. A promise resolving
onto an answer already on the drain chain is a `ResolutionCycle` error, surfaced
loudly instead of looping.

### op:get and op:index

The model also carries top-level `Get { receiver, field, answer }` and
`Index { receiver, index, answer }` arms for the OCapN `op:get` / `op:index`
wire shapes, and the Syrup codec encodes and decodes both on every profile. A
`field` pipeline path-step is a Cap'n Proto-only operand that the Syrup
decomposer and reference encoders reject loudly; Syrup does not translate it
into `op:get`. Serving these ops against a local object model is not implemented
in the engine — a received op surfaces an application event and records receipt,
the boundary the actor layer later closes.

## Scope (what this does not decide)

- **Syrup still decomposes multi-hop paths.** Cap'n Proto can carry a pipeline
  path as a native frame operand, encoding a multi-hop expression in one frame.
  Syrup has no equivalent operand, so multi-hop Syrup sends decompose through
  chained `op:deliver` frames. Codec posture:
  [ADR-0003](ADR-0003-codec-interoperability-posture.md).
- **Computing a resolved value against a local actor model is not implemented.**
  A drained call whose target resolved to a local export is re-targeted and
  surfaced as a synthesized `op:deliver` event
  ([`Peer.deliverDrainedCallLocally`](../../../src/ocapn/engine/mod.zig)) for
  the application to dispatch; the engine runs no method itself.
- **Export listeners are not implemented.** An `op:listen` on one of our own
  exports falls through to ordinary recv handling.
- Listeners on third-party handoff-imported promises and their relayed
  resolutions — [ADR-0009](ADR-0009-three-party-handoff-substrate.md).
- The `op:resolve` ↔ V1.0 resolver-callback translation the drain trigger rides
  on — [ADR-0010](ADR-0010-payload-descriptor-discriminator.md).

## Alternatives Considered

- **Decompose multi-hop on every codec for wire uniformity.** No competing codec
  exists to unify, and `decomposeOutboundDeliver` already produces the
  spec-canonical chained `op:deliver`. The reserved Cap'n Proto slot keeps
  native single-frame pipelining available when it lands.
- **Drop `PipelineOp.field` from the model.** Rejected: the gap is per-codec,
  not per-model. The model admits `field`; the Syrup path rejects it loudly so a
  structural step is never silently lost.
- **Own the queue in the engine.** Rejected: session state is authoritative. The
  engine drains through accessors that transfer ownership
  ([`Session.takePipelinedCalls`](../../../src/ocapn/session/mod.zig)); it holds
  no parallel queue.
- **Saturating or silent handling of queue overflow and resolution cycles.**
  Rejected: an unbounded queue or a forwarding loop is a partner-or-protocol
  fault, surfaced as `QueueCapExceeded` / `ResolutionCycle`.

## Consequences

- `Message.listen` and `FeatureSet.pipelining` gate the substrate; `op:listen`
  or pipelined delivery on a session that did not negotiate `pipelining` fails
  with `FeatureNotNegotiated`.
- The inbound answer table grows owned per-answer queues and listener lists;
  releasing an answer (GC, close) frees the queued calls, listener targets, and
  stored resolution it holds.
- Pipelining is exercised by in-process driven scenarios under
  [`src/oracle/`](../../../src/oracle/mod.zig) and the session/engine
  tests, against Goblins fixture shapes for the wire.

## Forward compatibility

A pipeline path reaches the wire only by decomposition. The reserved Cap'n Proto
slot would carry it natively, leaving the model surface and the drain semantics
unchanged — only the sender's choice of decompose-versus-emit moves. Any claim
of cross-codec pipelining parity stays unbacked until a second codec exists; the
harness exercises one ([ADR-0003](ADR-0003-codec-interoperability-posture.md)).

## Notes

[ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) settles the GC
shapes that release answer rows (the `count` on
[`AnswerEntry`](../../../src/ocapn/session/mod.zig)).
[ADR-0009](ADR-0009-three-party-handoff-substrate.md) extends listener
installation to handoff-imported promises.
