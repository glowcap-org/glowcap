---
id: ADR-0219
status: superseded
date: 2026-10-13
tags: [driver, runtime, performance, net]
decision: "HostRuntime parks inside the first resident's own kernel queue when every resident offers a park, and hands that resident every other wake descriptor to watch, instead of polling each resident's readiness descriptor."
supersedes: []
superseded_by: [ADR-0220]
amends: []
amended_by: []
---

# ADR-0219 A resident that owns a kernel queue is the park

[ADR-0220](ADR-0220-a-receive-re-arm-waits-for-the-park.md) consolidates this decision. It retains resident-owned parking and watch timing, and includes submission and deferred receive re-arms.

## Context

After [ADR-0213](ADR-0213-a-turn-submits-at-the-park.md) a turn's submissions
leave at the park, and the park itself was a `ppoll` over every resident's
readiness descriptor, the settle mailbox, and a stepped ready set's wake. On
the io_uring backend that poll paid twice per wake. A receive the kernel
completes for a parked thread is work it owes that thread, and it delivers
the work by interrupting the poll: the thread wakes, runs the receive, the
kernel restarts the poll, and the completion the receive posted wakes it
again. `strace` showed every park returning `ERESTARTNOHAND` once before
it returned ready. A wait inside the ring runs that owed work before it
checks the queue, so one wake reaps the reply. The backend already knew how
to wait in its own queue (`poll` with a timeout), and no caller used it for
the runtime's park.

## Decision

The resident contract (`src/net/multiplexed_resident.zig`) gains two
optional verbs that come together. `park` waits in the resident's own
kernel queue until a completion lands, a watched descriptor reads ready, or
the timeout passes, and turns what arrived into held records. `watch` names
a descriptor whose readiness ends the park without being consumed.
`HostRuntime` (`src/driver/host_runtime/pump.zig`) parks through the first
resident when every resident offers `park`, after handing it the mailbox
wake, the stepped ready set's wake, and its siblings' readiness descriptors.
After the park every sibling reaps, as the descriptor poll would have
selected it. When any resident lacks `park`, the runtime polls the readiness
descriptors as before, so a readiness-only resident keeps its contract.

The completion resident (`src/net/completion_resident/completions.zig`)
arms each watch as the park begins, through the backend's one-shot
`submitPoll`, and the watch's completion disarms it. Arming at the park, not
at `before_wait`, is what keeps a wake from being lost: a descriptor that
reads ready as the park begins completes inline and ends the park at once,
where a watch armed earlier could be reaped by a verb's pump and leave the
park asleep beside the wake it announced.

The io_uring backend's `poll` (`src/net/completion/uring.zig`) waits with
`io_uring_enter` and an extended argument for the timeout, and requires the
kernel feature that accepts one at construction. The provided-buffer ring it
already needs is newer than that feature, so no kernel floor moves.

## Scope (what this does not decide)

- A stepped embedder still parks outside on the ready set's descriptor. Only
  the runtime's own waits move into the ring.
- A runtime with no resident yet and a mailbox or ready set to wait on still
  polls those descriptors.
- The turn's submissions still leave in their own enters before the park. A
  send that completes inline would satisfy a combined submit-and-wait at
  once, so merging the two would add a wake, not remove one.

## Alternatives Considered

- **Register the wake descriptors as multishot polls once.** Rejected: a
  descriptor that stays readable keeps posting, and the runtime drains the
  mailbox and ready set only at its loop top.
- **Arm the watches at `before_wait` with the rest of the turn's queue.**
  Rejected: the inline pump that follows the submit reaps a watch whose
  descriptor was already ready, and the park then sleeps past that wake. The
  resident test and the off-turn settle test both caught it.
- **Make `park` the only wait and drop the readiness poll.** Rejected: test
  residents and any readiness-only resident keep the contract's descriptor
  as their one wake, and the runtime owns the choice per registration set.

## Consequences

- One pinned `tcp` round trip wakes each side once per direction. The
  benchmarks page carries the pinned rows.
- Every resident in `src/` is a completion resident, so every product
  runtime parks in the ring. The readiness poll remains for mixed sets.
- `ready_pending` reports a latched resident failure beside held records, so
  a park whose wait fails is serviced and the failure reaches `drain_ready`.

## Evidence and gate

- `test/net/completion_resident_test.zig`, "completion resident parks in its
  own queue and a watched descriptor wakes it": a bounded park ends on its
  bound, a nudge from another thread ends a park and consumes nothing, and
  a nudge that lands before the next park ends that park at once even after
  a reap saw it.
- `test/driver/off_turn_settle_test.zig`: a worker thread's mailbox post
  wakes a runtime parked in its resident's ring, twice in one session.
- `test/net/uring_test.zig`, "io_uring finite wait returns an empty turn when
  interrupted", now against the ring wait.
- The benchmarks page holds the pinned rows and the syscall profile:
  five ring enters per `tcp` round trip and no `ppoll`.
