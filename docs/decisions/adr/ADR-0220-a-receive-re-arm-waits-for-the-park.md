---
id: ADR-0220
status: accepted
date: 2026-10-13
tags: [driver, net, performance, runtime]
decision: "A runtime submits staged sends before returning to callers, defers blocking receive re-arms until the next park, and waits inside a resident kernel queue when the registration set supports it."
supersedes: [ADR-0213, ADR-0219]
superseded_by: []
amends: [ADR-0212]
amended_by: [ADR-0214, ADR-0215]
---

# ADR-0220 Runtime submission and parking

## Context

Submitting each operation as a runtime verb ends creates separate kernel
entries for sends and receive re-arms. A turn can produce several batches
for one connection, including an answer and reference releases. Submitting
them together reduces sends and wakeups.

A blocking caller may stay away after its verb returns. Staged replies must
leave before that happens. Receive re-arms can wait until the next park,
because the peer's bytes remain in the socket until the runtime returns.
A stepped embedder instead relies on readiness while parked outside the
runtime and needs every receive armed when its turn ends.

## Decision

The resident contract distinguishes a turn followed by `park` from one
followed by `caller`. Before its own wait and at the end of a stepped turn,
HostRuntime passes `park` to `before_wait`. At the end of a blocking verb it
passes `caller`. Verbs that can arm work enter the driver, including listener
startup, so an accept is armed before control returns to a stepped embedder.

The completion resident queues stream sends until `before_wait`, combining
the turn's staged batches for one connection into one send. Message-framed
connections preserve packet boundaries. Sends leave on both turn endings.
Receive re-arms stay in the resident's receive queue until a `park` ending,
when they submit with queued sends. A queued receive answers would-block.
Readiness backends arm their interest at the same point.

Reaping is separate from submission. The backend's required `peek` takes
completed work without submitting, so a verb can reap without entering the
kernel. A flush reaps inline completions and submits any follow-up work
needed before the wait. An inline send completion that leaves no record
must not satisfy the next park.

When every registered resident offers paired `park` and `watch` verbs,
HostRuntime waits inside the first resident's kernel queue. That resident
watches the mailbox, stepped ready-set wake, and sibling readiness
descriptors without consuming them. Siblings reap after the wait. A mixed
set containing a readiness-only resident uses the descriptor poll, as does
a runtime waiting without a resident.

Watches arm as the park begins and disarm on completion. A descriptor
already ready must end that park even if an earlier reap saw it. Arming
watches at the earlier flush could consume the only notification before the
wait and lose a wake. Wait failures remain latched work reported by
`ready_pending`, so ordinary service delivers them to the caller.

The io_uring wait uses the kernel queue's finite timeout support. Submission
and waiting remain separate: a send completing inline must not end a wait
that should receive the reply. A stepped embedder continues to wait on its
external readiness descriptor.

## Alternatives Considered

- **Submit inside every verb.** Receive re-arms and separate batches pay
  individual kernel entries.
- **Skip the entire blocking verb-end flush.** A reply can remain staged
  until an application chooses to call again.
- **Discover free receives by scanning every connection at the park.**
  A resident-owned queue already names precisely the work waiting to arm.
- **Use only resident parking.** Readiness-only residents still need the
  descriptor contract.
- **Arm persistent watches before the park.** Earlier reaping can lose a
  notification, and a readable multishot watch can repeatedly post until
  the runtime reaches its loop top.

## Consequences and evidence

Submission follows visible work rather than every verb boundary. Blocking
applications can defer receive re-arms while away, and stepped applications
retain readiness behavior. The resident owns queued operations and their
completion state, while HostRuntime owns when the caller will wait.

`src/net/multiplexed_resident.zig` declares the contract.
`src/net/completion_resident/completions.zig` owns queued operations and
watches, and `src/driver/host_runtime/pump.zig` owns wait selection.
`test/net/completion_resident_test.zig` covers batch submission, deferred
re-arms, bounded parks, and wakes already ready before the wait.
`test/driver/host_runtime_multiplexed/lifecycle_test.zig` covers both runtime
faces. `test/driver/off_turn_settle_test.zig` checks cross-thread mailbox
wakes. `test/net/uring_test.zig` checks interrupted finite waits.

## Related decisions

ADR-0212 owns held-record readiness. ADR-0214 owns answer-release batching,
and ADR-0215 owns optional busy polling before the park. Their independent
policies apply to this submission and waiting contract. Measured syscall
counts and timings belong in `bench/README.md`.
