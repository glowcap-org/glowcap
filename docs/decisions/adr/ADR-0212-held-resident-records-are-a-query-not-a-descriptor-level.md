---
id: ADR-0212
status: accepted
date: 2026-10-13
tags: [driver, runtime, performance, net]
decision: "A completion resident reports the records it holds between a verb and its next service through `ready_pending`. HostRuntime services such a resident before it parks and raises the stepped readiness descriptor when a verb leaves records behind. The resident no longer keeps its descriptor readable with a wake channel."
supersedes: []
superseded_by: []
amends: [ADR-0202]
amended_by: [ADR-0220]
---

# ADR-0212 Held resident records are a query, not a descriptor level

## Context

[ADR-0202](ADR-0202-stream-transports-join-hostruntime-as-a-completion-resident.md)
made the completion resident's readiness descriptor level-shaped: it had to
read ready while any drained record waited. The resident ends every verb with
a nonblocking reap, so a receive that completes while the runtime is writing
a reply is turned into a record inside that verb, where no descriptor reports
it. To keep the level, the resident owned a wake channel, armed a readiness
poll on it through the backend, and wrote a byte to it whenever records
waited.

On a server answering a fast client, the next call's receive lands in the
reply's own flush on most turns. Each such turn cost a pipe write, a poll
submission and its completion, and two reads to drain the byte, before the
runtime's own wait even began. Measured with `strace -f -c` on
`zig build bench-iroh -- --transport=tcp`, one TCP round trip spent four of
those wakes and eight pipe reads, and the completion ring backend added a
zero-timeout `ppoll` and an empty submit on every reap.

## Decision

The `MultiplexedResident` contract gains an optional `ready_pending` query:
whether records already taken from the kernel wait in the resident now. The
descriptor contract narrows to what the kernel holds. HostRuntime asks every
resident before it parks (`waitAnySource` returns a resident that reports
pending records without polling) and, on the stepped face, raises its
readiness descriptor when the outermost verb returns while any resident
holds records (`publishResidentRecords`, called from `leaveDriver`). This is
the owner that already publishes paused inbound bytes and deferred releases
to a stepped embedder, so held records join that list instead of carrying
their own channel.

The completion resident drops its wake channel, the armed readiness poll, and
the cancel that retired it at teardown. The webrtc backend drops the foreign
poll slot that existed only for that wake. The io_uring backend submits only
when its submission ring holds an entry and treats a zero-timeout poll as a
peek of the shared completion ring, with no wait syscall.

## Scope (what this does not decide)

The stepped embedder's loop is unchanged: wait on the descriptor for at most
`stepWaitMs`, then step with a zero timeout. Residents that complete into the
kernel only (iroh, the C ABI adapters) leave `ready_pending` absent.

## Alternatives Considered

- **A ring no-op submission as the nudge**: cheaper than the pipe on io_uring,
  but epoll and kqueue can only signal through a descriptor, so it would be a
  second mechanism beside the pipe.
- **A bound of zero from `wait_bound_ms` while records wait**: the runtime
  still polls, and the stepped embedder's park outside the runtime still
  needs the descriptor raised.

## Consequences

`src/net/multiplexed_resident.zig` carries the query. `src/net/completion_resident.zig`
and `completion_resident/{completions,teardown}.zig` lose the wake state.
`src/driver/host_runtime/{pump,step,shutdown}.zig` own the two publication
points. `src/net/completion/uring.zig` owns the submit and peek rules.

## Evidence and gate

- `test/net/completion_resident_test.zig`, "completion resident reports
  records it holds between a verb and its service".
- `test/driver/host_runtime_multiplexed/lifecycle_test.zig`, "a blocking step
  services a record a resident holds without a descriptor wake" and "a verb
  that leaves a resident holding a record raises the stepped readiness
  descriptor".
- Syscalls per `tcp` round trip under `strace -f -c` on the ladder's machine:
  73 before (44 ring enters, 17 polls, 8 pipe reads, 4 pipe writes) and 8
  after (6 ring enters, 2 polls). The ladder's ceiling table holds the
  measured round trip.
