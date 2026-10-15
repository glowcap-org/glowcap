---
id: ADR-0215
status: accepted
date: 2026-10-13
tags: [driver, runtime, performance, net]
decision: "A HostRuntime with a busy-poll window spins before it parks: each pass reaps every resident through the resident contract's `reap` and asks `ready_pending`, so a reply that lands inside the window is serviced without a descriptor wake. The window is zero by default, bounded by the caller's wait budget, and set by an embedder that owns a core."
supersedes: []
superseded_by: []
amends: [ADR-0220]
amended_by: []
---

# ADR-0215 A runtime may spin before it parks

## Context

After [ADR-0214](ADR-0214-answer-releases-ride-the-next-message.md) one
`tcp` call round trip parked twice and entered the ring three times, and
the park was the largest remaining cost: on two cores the round trip
measured 17 µs against a 4.6 µs loopback floor with both sides spinning.
An `inproc` round trip moved its bytes through memory and still cost 14 µs,
almost all of it the park and the wake that ends it.

The runtime parked in `waitAnySource` on every resident's readiness
descriptor as soon as no resident held a record. Nothing between the flush
and the park looked at the kernel's completion queue, which the ring backend
reads from userspace without a syscall.

## Decision

`HostRuntime.Options.busy_poll_ns` names how long the blocking face spins
before it parks. Zero, the default, parks at once. `waitAnySource` runs the
spin after the resident flush and the ready scan: each pass asks every
resident to `reap` and then `ready_pending`, and the first resident holding
a record is serviced as if its descriptor had fired. The window is bounded
by the caller's wait budget and by the nearest pending deadline (a close
grace, a dial budget, a retry due), the same bound the park takes, and the
time spent comes off that budget, so a step with a 20 ms timeout and a 30 s
window returns in 20 ms. A window past `HostRuntime.max_busy_poll_ns` is
refused at adoption, in Zig and at the C boundary
(`GLOWCAP_DRIVER_MAX_BUSY_POLL_NS`), because a cross-thread settle or wake
waits out the whole window.

The `MultiplexedResident` contract gains an optional `reap` verb: take what
the kernel completed since the last reap and hold it as records, submitting
nothing. The completion resident answers it with its existing `pump`, whose
backend `peek` reads the ring without entering the kernel. A resident
without `reap` is passed over by the spin and learns of work through its
descriptor as before.

A spinning runtime holds its CPU for the window and sees a cross-thread
wake, a mailbox settle, or a stepped embedder's readiness wake only when
the window ends or a resident has a record. The option's doc says so, and
an embedder sets it on a runtime that owns a core, bounded by the reply
latency it expects. Two runtimes that share a core and both spin wait out
each other's window on every call, so the benchmarks pin each to its own
core with `--pin=A,B`.

A resident whose writers would wake it learns whether a wake is needed
from the same two verbs. The `inproc` sink carries a parked flag: the
wrapper's `flush` marks it parked, its `peek` and a zero wait mark it
looking, and a writer that queues news for a looking owner sends no nudge,
since that owner's next reap settles the queue. An owner that parks over
news it has not reaped nudges itself, so the flag never loses a wake. A
spin that ends without a record therefore flushes the residents once more
before the park, which marks every such sink parked again and takes what
that flush completed.

## Scope (what this does not decide)

- The stepped face's own park, which the embedder owns outside the runtime.
  The window applies to the runtime's wait inside a step, bounded by the
  step's budget.
- An adaptive window. The runtime spins for the whole window or until a
  record lands. A window that grows and shrinks with observed latency is a
  policy for the embedder or a later decision.
## Alternatives Considered

- Spin inside the completion backend's `poll` with a zero timeout. Rejected:
  that path submits before it reads, so every pass would enter the kernel.
- Let the kernel poll the submission queue (`IORING_SETUP_SQPOLL`). Rejected
  for this decision: it removes the submit's enter, not the park, and the
  application still has to reap. It is a ring-only, Linux-only setting and
  can join later as a backend option beside this one.
- A spin inside each resident, below the runtime. Rejected: the runtime owns
  the park and the wait budget, and a resident spinning on its own would
  starve the mailbox and the other residents of the same runtime.

## Consequences

- One `tcp` call round trip on two cores with both runtimes spinning parks
  zero times and enters the ring three times, for the sends and the re-armed
  receive. One `inproc` call round trip with both spinning makes no syscall.
  The benchmarks page holds the measured rows.
- A resident that reaps completions inside verbs implements `reap` so a
  spinning runtime sees its records. The completion resident does. The fake
  resident in the runtime tests counts its reaps.
- `waitAnySource` reduces the caller's timeout by the time the spin took.

## Evidence and gate

- `test/driver/host_runtime_multiplexed/park_test.zig`: a busy-poll
  window services a record that lands on the spin's third reap without a
  descriptor wake, a window longer than the step's budget returns within
  that budget, and a window past the maximum is refused at adoption.
- `test/driver/host_runtime_step/dial_retry_test.zig`: a window ends at a
  retrying dial's due, as the park it replaces would.
- `test/net/inproc_completion_test.zig`, "a writer nudges only a parked
  reader": a looking reader's wake channel stays quiet and its next pass
  settles the news, a parked reader is nudged, and a reader that parks over
  unreaped news wakes itself.
- `bench-iroh --busy-poll-us=<n> --pin=A,B` sets the window on every
  runtime a row builds and gives each its core, and `bench-floors` gains the
  loopback round trip with both sides spinning, the floor a spinning runtime
  pays.
- Syscalls per `tcp` round trip under `strace -f -c` with a 200 µs window:
  no `ppoll` and three ring enters, against two parks before.
