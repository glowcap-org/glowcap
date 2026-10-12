---
id: ADR-0065
status: accepted
date: 2026-06-18
tags: [pipelining, driver, c-abi, bindings, tcp, nagle, questioner]
decision: A questioner addresses a verb at an answer it has not settled by passing the handle a prior send returned back to `send` (`Session.send`/`sendToAnswer`/`settleVow` in the Zig driver, `glowcap_peer_send_deliver`'s answer target under the owning C session, and a vow-as-send-target in every binding) so a dependent chain costs one round trip. The deliver is queued at the send and the batch flushes on the first settle. The TCP transport disables Nagle on every dialed and accepted socket so the batched-then-await pattern does not eat a delayed-ACK stall.
supersedes: []
superseded_by: []
---

# ADR-0065 Questioner-side promise pipelining

## Context

[ADR-0007](ADR-0007-promise-pipelining-substrate.md) decided the serving half:
how a peer queues an `op:deliver` addressed at a still-pending answer, drains it
FIFO on resolution, and decomposes a multi-hop send into chained single-hop
`op:deliver`s. The questioner half (how an application issues a pipelined send
and settles the one answer it cares about) was engine-internal plumbing
reachable only through the raw peer.

The gap was ergonomic, not protocol. A consumer that writes `create` then
`assign`/`complete`/`status` on the returned task pays four serial round trips if
it awaits each step, although the wire can address the later three at the answer
`create` will resolve to. One shape across the Zig driver, the C ABI, and all
four language bindings makes a dependent chain cost one round trip in every
consumer.

## Decision

### One shape: a returned handle is a send target

The Zig driver ([`src/driver/session.zig`](../../../src/driver/session.zig))
exposes the questioner triad: `send(target, msg)` returns an answer `Vow`
without settling it. `sendToAnswer(vow, msg)` addresses a verb at that pending
answer (the wire `desc:answer`, ADR-0007). `settleVow(vow, arena)` drives
until a chosen answer settles. The flush is deferred to the next settle, so a
batch of sends leaves the wire together. The triad delegates to
[`BlockingSession`](../../../src/driver/blocking_session.zig), which owns the answer
bookkeeping over the engine's `allocateAnswer`.

The byte-fed Host owns the binding-facing send/settle pair. (The retired raw C
peer carried the same seam through `glowcap_peer_send_deliver`, taking an
optional answer target, until ADR-0096.)

Every binding renders the triad in its own idiom, and in each one the handle a
send returns is a valid target for the next send: Rust's `RemotePromise`
implements `AsSendTarget`, Python's and TypeScript's `Session.send` accept a
`RemotePromise`, and Racket's `session-send-promise` returns a `promise-ref` that
`session-send`/`session-send-promise` pipeline against, settled by `session-await`. A
pipelined send to a local-only handle (one with no far answer) is refused.

### The transport does not stall the batch

The questioner pattern is write-a-batch-then-await. Nagle's algorithm holds a
small trailing segment until the prior one is ACKed, and an idle peer only ACKs
on its ~40 ms delayed-ACK timer, so a batched send can wait on a timer for
nothing, which erases the benefit of pipelining. The TCP transport
([`src/net/transport/tcp.zig`](../../../src/net/transport/tcp.zig),
`setNoDelay`) sets `TCP_NODELAY` on every dialed and accepted socket, where it
turns an `Io` into a socket. It is best-effort: a stream whose option cannot be
set still works, with coalescing.

## Scope (what this does not decide)

- **The serving half is unchanged.** Queueing, draining, the listener matrix, and
  multi-hop decomposition stay as [ADR-0007](ADR-0007-promise-pipelining-substrate.md)
  settled them. This ADR covers the caller-facing surface that drives them.
- **Projections (`op:get`/`op:index`/`op:untag`) are their own seam.** A vow's
  `get`/`index`/`untag` pipeline a structural step
  ([ADR-0050](ADR-0050-get-index-responder.md), [ADR-0052](ADR-0052-untag-responder.md)).
  This ADR covers verb sends at an answer, not field navigation.
- **No new wire shape.** A pipelined questioner send is the `op:deliver` against a
  `desc:answer` that ADR-0007 already carries.

## Alternatives Considered

- **Leave pipelining to the raw peer.** Rejected: a hand-allocated answer is
  correct but not the easy path, and consumers awaited each step and paid serial
  round trips. A vow-as-target makes the fast path the obvious one.
- **A separate `pipeline()` method distinct from `send()`.** Rejected: it adds a
  second verb. Overloading send on the target type keeps one surface, and the
  type (capability or vow) says whether it pipelines.
- **Leave Nagle on and document the stall.** Rejected: a request/response wire
  gains nothing from Nagle and loses a round trip to it.

## Consequences

- The `bench-langs` throughput unit runs the four-verb taskboard script pipelined
  in every client (the latency unit stays sequential), so the per-language report
  measures the pipelined steady-state rate. The Goblins-reference row uses
  Goblins' native pipelining to keep the workload identical
  ([`bench/langs/contract.md`](../../../bench/langs/contract.md)).
- Disabling Nagle drops the per-round-trip delayed-ACK stall on the TCP path:
  loopback `bench-langs` throughput rose by two to three orders of magnitude once
  the batched send stopped waiting on the ACK timer.
- The questioner triad is exercised by each binding's `zig_smoke` pipelining
  proof and the driver/actor scenarios. The wire shape it rides is the ADR-0007
  substrate the session/engine tests and live Goblins / suite arms already cover.

## Notes

[ADR-0007](ADR-0007-promise-pipelining-substrate.md) is the serving substrate
this surface drives. [ADR-0062](ADR-0062-one-connect-over-a-netlayer-slice.md)
owns the C session the bindings sit on.
