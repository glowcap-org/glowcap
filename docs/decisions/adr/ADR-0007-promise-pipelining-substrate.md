---
id: ADR-0007
status: accepted
date: 2026-05-04
tags: [pipelining, op-listen, queue, fifo-drain, syrup-decompose, listener-fire]
decision: A pipelined `op:deliver` against a still-pending inbound answer queues FIFO on that answer's entry and drains through the bounded exact-incarnation resolution chain when the answer settles. `op:listen` and projection operations use the same chain. A promise reference is exactly one `desc:answer` position. Derived calls and projections are ordinary operations with their own answer positions.
supersedes: []
superseded_by: []
amended_by: [ADR-0111]
---

# ADR-0007 Promise pipelining substrate

## Context

A caller can address an `op:deliver` at a promise: an answer the partner has
not resolved yet. OCapN's wire target for that
case is `<desc:answer answer-pos>`, a single positive integer (CapTP
Specification.md § desc:answer). Chained pipelining is a sequence of ordinary
operations, each naming the prior operation's answer. `op:get`, `op:index`, and
`op:untag` provide the structural projections.

Two questions follow. Where does a call queued against an unresolved answer
live, and how does it drain when the answer settles? How do listeners and
projections keep that answer's incarnation across release and reuse?

`op:listen` is the sibling operation: it installs a party to be told when an
answer changes. Goblins V1.0 uses a Boolean `wants-partial?` operand. The next
profile uses the integer modes from the pending OCapN promise-listening
proposal: shortening only, settling only, or either.

## Decision

### Queue ownership and drain

The inbound answer table owns pipelining state.
[`AnswerCell`](../../../src/ocapn/session/answers/store.zig) carries a FIFO `queue` of
owned `op:deliver` messages, a `listeners` list, and the stored `resolution`. An
inbound `op:deliver` whose target is a still-`pending` answer is held there
([`Session.enqueuePipelinedCall`](../../../src/ocapn/session/mod.zig)) and
surfaces no application event.
[`pipeline.preparePipelinedCall`](../../../src/ocapn/engine/pipeline.zig) makes that
decision at dispatch time.

When a `Peer` settles that answer, `step` drains the queue
([`pipeline.drainAnswerConsequencesTarget`](../../../src/ocapn/engine/pipeline.zig)) and then fires
the matching listeners. V1.0 sends a resolver callback. Next uses the mandatory
listener that followed the answered operation and has no wire `op:resolve`.
Calls drain first because a drained call may settle further answers.
Each queued call dispatches against the resolution
([`pipeline`](../../../src/ocapn/engine/pipeline.zig)): a `far`
resolution forwards the call on the wire (target rewritten via
[`pipeline.rewriteDeliverTarget`](../../../src/ocapn/engine/pipeline.zig)). A
`near` resolution delivers locally. Another promise follows the exact answer
incarnation captured when the resolution was stored. A pending terminal queues
there directly. A released or cyclic chain breaks only the dependent call.

### Listener fire matrix

[`pipeline.classifyListenerDrain`](../../../src/ocapn/engine/pipeline.zig)
decides each listener's fate from the resolution and its mode. A same-peer
promise fulfillment re-anchors the listener without notification. A settled
value or break fires a mode that requested settlement. A far promise is a
promise the listener's peer hosts. On V1.0 it fires every listener: the
spec exempts only same-peer promises, Goblins listens with wants-partial `#f`
and no second listener, and the listener's peer follows its own promise
locally. On next it fires only a mode that requested shortening, because each
settling listener there is paired with a shortening one that reissues it
(ADR-0111). Every notification concludes that subscription and is sent through
[`pipeline.borrowedListenerFire`](../../../src/ocapn/engine/pipeline.zig),
which builds the resolver-method `op:deliver` (`[Symbol("fulfill"), payload]` or
`[Symbol("break"), Symbol(reason)]`, the shape the upstream suite pins) as a
borrowed stack message over the stored resolution. The queue holds only a POD
carrier stamped with the store row's identity, so a fire staled by the row's
release cannot emit a reused row's payload. Drain order is arrival order, which
matches Goblins's promise-queue draining and the transitive forwarding the
OCapN spec describes (Model.md § Promise).

### Derived operations stay explicit

`PromiseRef` carries only the answer position encoded by `desc:answer`.
Pipelining through a call is another `op:deliver` with a fresh answer.
Projecting a value is `op:get`, `op:index`, or `op:untag`, also with a fresh
answer. Each operation crosses the normal validate/apply and outbound-admission
transaction independently. The model, codecs, stored resolutions, and
incarnation walker therefore share one reference meaning, and no unevaluated
argument tree enters capability identity.

### Bounds

[`SessionLimits`](../../../src/ocapn/session/mod.zig) caps each surface:
`queue_cap` per pending answer (`QueueCapExceeded`), `max_listeners_per_target`
(`ListenerCapExceeded`), `max_inbound_answers`, `max_resolution_chain` for the
shared stored-resolution walk, and `max_local_deliveries` for the chain of local
deliveries one resolution can trigger. A cycle or overlong chain becomes a
terminal break for its dependent calls, listeners, and projections without
condemning the session.

### op:get and op:index

The model also carries top-level `Get { receiver, field, answer }` and
`Index { receiver, index, answer }` arms for the OCapN `op:get` / `op:index`
wire shapes, and both codecs encode and decode them. The engine answers these
ops by projecting field/index once the receiver settles
([ADR-0050](ADR-0050-get-index-responder.md)). `op:untag` rides the same
substrate ([ADR-0052](ADR-0052-untag-responder.md)).

## Scope (what this does not decide)

- **Operation batching.** A caller may issue a chain of derived operations, but
  core does not present the sequence as one atomic message. Each operation has
  its own answer lifetime and admission result.
- **Computing a resolved value against a local actor model.** A drained call
  whose target resolved to a local export is re-targeted and surfaced as a
  synthesized `op:deliver` event
  ([`Peer.deliverDrainedCallLocally`](../../../src/ocapn/engine/mod.zig)) for
  the application to dispatch. The engine runs no method itself.
- **Export-side listen: object exports fire, bare promise exports refuse.** A
  listen on a live object export (held `local_value`, no inbound answer) fires
  fulfill of that export immediately. A listen on a bare unresolved promise
  export is refused with `InvalidReference`. glowcap exports no free-standing
  resolvable promise. The only promise exports it mints are resolver callbacks
  the partner delivers to and never listens on, so a listener on one could never
  fire, and accepting it would owe a subscription forever. A
  partner that wants resolution notification listens on the inbound answer it
  already holds.
- Listeners on third-party handoff-imported promises and their relayed
  resolutions, [ADR-0009](ADR-0009-three-party-handoff-substrate.md).
- Profile-specific answer notification is amended by
  [ADR-0111](ADR-0111-next-promise-listeners.md). V1.0 resolver callbacks remain
  under [ADR-0010](ADR-0010-payload-descriptor-discriminator.md).

## Alternatives Considered

- **Embed a derived-operation path in `PromiseRef`.** Rejected: OCapN assigns no
  such semantics to `desc:answer`, and argument validation, export accounting,
  answer-incarnation identity, listener shortening, and resolution GC would
  recursively depend on an unevaluated program. Explicit operations reuse the
  existing authorities and work identically through every codec.
- **Own the queue in the engine.** Rejected: session state is authoritative. The
  engine drains through accessors that transfer ownership
  ([`Session.takePipelinedCalls`](../../../src/ocapn/session/mod.zig)). It holds
  no parallel queue.
- **Silent handling of queue overflow and resolution cycles.** Rejected: queue
  overflow is `QueueCapExceeded`, and a forwarding cycle is an explicit
  dependent break.

## Consequences

- `Message.listen` and `FeatureSet.pipelining` gate the substrate. `op:listen`
  or pipelined delivery on a session that did not negotiate `pipelining` fails
  with `FeatureNotNegotiated`.
- The inbound answer table grows owned per-answer queues and listener lists.
  Releasing an answer (GC, close) frees the queued calls, listener targets, and
  stored resolution it holds.
- Pipelining is exercised by in-process driven scenarios under
  [`src/oracle/`](../../../src/oracle/mod.zig) and the session/engine
  tests, against Goblins fixture shapes for the wire.

## Forward compatibility

New codecs map the same position-only promise reference and explicit operation
messages. A derived-path operand would need a separate semantic operation and
conformance evidence, not a wider encoding of `desc:answer`.

## Notes

[ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) settles the GC
shapes that release answer rows (the `count` on
[`AnswerCell`](../../../src/ocapn/session/answers/store.zig)).
[ADR-0009](ADR-0009-three-party-handoff-substrate.md) extends listener
installation to handoff-imported promises.
