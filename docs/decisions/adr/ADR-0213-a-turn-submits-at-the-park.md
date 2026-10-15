---
id: ADR-0213
status: superseded
date: 2026-10-13
tags: [driver, runtime, performance, net]
decision: "A completion resident hands a turn's staged sends and queued ring submissions to the kernel when HostRuntime parks or a verb returns to its caller, through the resident contract's `before_wait`. Between verbs it reaps with `peek`, a submit-free read every completion backend provides."
supersedes: []
superseded_by: [ADR-0220]
amends: []
amended_by: []
---

# ADR-0213 A turn submits at the park

[ADR-0220](ADR-0220-a-receive-re-arm-waits-for-the-park.md) consolidates this decision. It retains send batching and verb-end send submission, and defers blocking receive re-arms until the park.

## Context

After [ADR-0212](ADR-0212-held-resident-records-are-a-query-not-a-descriptor-level.md)
one `tcp` call round trip still entered the ring six times. A probe that
printed the submission queue at each submit showed one entry per enter: the
completion resident ended every verb with a reap followed by a submit, and
`flush_writes` started a send for each batch the runtime wrote. A server
turn writes its answer and then, in a later verb of the same step, the
`op:gc-exports` that releases the arguments, so the two left in two sends,
arrived as two segments, and cost the client two receives and two wakes.

The ring backend's zero-timeout `poll` also submitted before it read, so a
verb could not reap without entering the kernel.

## Decision

The `MultiplexedResident` contract gains an optional `before_wait` verb: the
runtime is about to park on the descriptor, or a verb is returning to a
caller who may park or stay away, and the resident hands everything it has
staged or queued to the kernel now. HostRuntime calls it on every resident
in `waitAnySource`, before it asks `ready_pending`, and in `leaveDriver` at
depth zero on both faces. A verb's end flushes because the caller may not
return soon, and an answer produced inside the verb must leave regardless.
So every runtime verb that can arm resident work enters the driver, the
listener verbs included: an accept armed by `startListener` from a stepped
embedder leaves as that verb returns, not at an embedder's later step.

The completion resident's `flush_writes` queues the connection instead of
starting a send, so every batch a turn writes to one connection leaves in one
send. A message-framed connection still starts at `flush_writes`, because one
packet is one batch. `before_wait` starts the queued sends, submits, reaps
what that submit completed inline (a loopback send finishes inside it, and
its completion must not wake the park), and submits once more for anything
the reap armed. A verb ends with a reap alone.

The completion backend contract gains `peek`: reap what the kernel already
completed and submit nothing. `validateBackend` requires it, so a wrapper
backend threads it to its platform and a readiness backend answers with a
zero-timeout poll.

## Scope (what this does not decide)

- When the session emits `op:gc-answers`. The client releases each answer at
  the tail of the `call` that consumed it, so that frame still leaves in its
  own send as the verb returns. Batching it behind the next outbound frame
  is a protocol policy decision, recorded as the next item on the
  performance plan.
- The stepped face's park, which the embedder owns. The verb-end flush is
  what that embedder relies on.

## Alternatives Considered

- Keep submitting inside verbs and batch only the sends. Rejected: every
  re-armed receive would still cost its own enter.
- Offer `peek` as an optional backend capability probed with `@hasDecl`.
  Rejected: the backend contract forbids soft optionality at call sites, and
  the Linux backend is a union whose probe would have missed the ring.
- Skip the verb-end submit on the blocking face so the next park carries the
  whole turn. Rejected: an answer written while a verb waited would sit until
  the application's next verb, a latency it cannot see or bound.

## Consequences

- One `tcp` round trip enters the ring four times and parks twice. The
  server's answer and its `op:gc-exports` leave in one send.
- The pinned round trip is unchanged, because the remaining cost is the
  server's second wake for the client's `op:gc-answers` send and the context
  switches it costs on one CPU.
- Anything that drives a resident directly, such as a scenario parking on its
  descriptor, calls `before_wait` before the park and asks `ready_pending`,
  as the runtime does.

## Evidence and gate

- `test/net/completion_resident_test.zig`, "completion resident holds every
  flushed batch of a turn for one send at the park".
- `test/driver/host_runtime_multiplexed/lifecycle_test.zig`: the blocking
  step calls `before_wait` at its park and as it returns, and the stepped
  verb calls it as it returns.
- `test/c_abi/driver_loop/listener_test.zig`, "an unselected listener refuses
  accept visibly until routing policy is selected": the accept armed by the
  C listen call is live before the embedder's next step.
- Syscalls per `tcp` round trip under `strace -f -c` on the benchmarks page's machine:
  6 ring enters and 2 parks before, 4 ring enters and 2 parks after. The
  product-path table in `bench/README.md` holds the measured round trip.
