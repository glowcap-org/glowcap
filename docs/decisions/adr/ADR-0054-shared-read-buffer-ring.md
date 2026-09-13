---
id: ADR-0054
status: accepted
date: 2026-06-11
tags: [net, runtime, memory, performance, resilience]
decision: "Completion-loop connections hold no per-connection read buffer. The backend owns one shared pool of `BackendOptions.read_buffers` buffers (io_uring: a kernel provided-buffer ring; kqueue: a poll-time scratch pool), a recv completion lends the loop a borrowed view of the selected buffer, and the loop recycles it exactly once after consuming: whole frames apply zero-copy from the view, a partial tail absorbs into the bounded spill (ADR-0041). A recv that finds the pool empty parks the connection buffer-starved and resumes on recycle; it is never dropped. Idle read-buffer memory no longer scales with connection count."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0152]
---

# ADR-0054 Shared read-buffer ring for the completion loop

## Context

ADR-0041 made the per-connection read buffer small and fixed (16 KiB), and
ADR-0042 bounded the outbound queue, but every live connection still _owned_ its
buffer for its whole life. At the 500k-connection destination the buffers alone
are ~7.63 GiB: roughly twelve times the ~0.65 GiB of warmed core state the
peer-scaling bench reports: and almost all of them sit idle at any given
moment, because a buffer is only doing work during the instant between data
arriving and the loop consuming it. Both ADRs named a shared buffer ring as the
completion loop's follow-up; this ADR closes it. It engages the same first
principle as its predecessors: every allocation on the wire path is forbidden,
intentional, or measured.

## Decision

**The backend owns one shared read-buffer pool; a connection borrows a buffer
per completion.** `submitRecv` no longer carries a caller buffer. The backend
(`src/net/completion/uring.zig`, `src/net/completion/kqueue.zig`) selects a
buffer from its pool of `BackendOptions.read_buffers` buffers (default 256), each
exactly `BackendOptions.read_buffer_bytes` bytes (default 16 KiB), when data
actually arrives, and the completion lends the loop a borrowed view of it
(`Completion.recv_bytes`). The loop
(`src/net/completion/loop.zig`) consumes the bytes and hands the buffer back
with `recycleRecv`, exactly once per completion that carried one. On io_uring
the pool is a kernel provided-buffer ring registered at init, with buffer-select
recvs; on kqueue, a readiness model that reads at poll time, it is a lazily
grown scratch pool the `poll` read borrows from.

**Whole frames stay zero-copy; the split tail rides the spill.** The loop
applies every complete frame directly from the borrowed view, advancing by
offset: the old per-connection compaction memcpy died with the owned buffer. A
partial frame tail cannot stay in a buffer that is about to be recycled, so it
absorbs into the connection's bounded spill (ADR-0041's machinery, freed on
drain) and the next completion's bytes extend it. The defensive
incomplete-at-cap mirror of the codec's cap-during-scan verdict is unchanged.

**Pool exhaustion parks the read; it never drops the connection.** A recv that
finds the pool empty completes as `recv_no_buffer` (io_uring reports `ENOBUFS`;
kqueue synthesizes the same shape when its scratch pool is spent). The loop
parks that connection buffer-starved on an intrusive list and re-arms it when a
buffer recycles, plus an end-of-batch sweep that re-arms every remaining starved
connection: a starved completion can be dispatched after the recycle that
should have resumed it, and the sweep closes that ordering gap. Starvation is
transient pool contention, not a failure, and it is distinct from the deliberate
high-water park (ADR-0042), which still wins: a starved connection whose
outbound is over the mark re-parks under ADR-0042 and resumes on drain.

**The named trade.** A frame split across recv boundaries now pays one bounded
copy of its tail into the spill, where the old persistent buffer let the tail
wait in place for free. In exchange, an idle connection holds zero read-buffer
memory: the read floor at 500k connections moves from ~7.63 GiB to
`read_buffers` × 16 KiB (4 MiB at the default), and total warmed footprint moves
from ~8.3 GiB toward the ~0.65 GiB core floor. Steady CapTP frames are far
smaller than one buffer, so the split tail is the rare case, exactly as the
spill always assumed.

## Scope (what this does not decide)

- **Multishot recv.** Each recv is still armed per completion. io_uring's
  multishot recv over the same buffer group would cut submission syscalls; it is
  not implemented.
- **Pool sizing policy.** `BackendOptions.read_buffers` and
  `BackendOptions.read_buffer_bytes` are static. Growing or shrinking the pool
  under observed contention is host policy that does not exist yet.
- **The blocking paths.** `pumpOver`, `FrameStream`, and the C-ABI endpoint keep
  their caller-owned read buffers; only the completion loop shares.

## Alternatives Considered

- **Per-connection buffers (status quo ante).** Rejected: idle read memory
  scales with connection count, ~12x the core state at 500k, which is the exact
  scaling problem the bench keeps visible.
- **io_uring multishot recv with the buffer group.** Deferred, not rejected: it
  is the natural next step on this ring, but it changes the one-completion-
  per-submit accounting the loop's teardown leans on, so it lands as its own
  change.
- **Loop-owned pool above a buffer-less backend interface.** Rejected: the
  kernel selects the buffer on io_uring, so ownership below the interface is the
  only shape both backends can implement honestly; the loop sees one contract.
- **Closing or erroring a connection on `ENOBUFS`.** Rejected: pool contention
  is the backend's own transient state, not partner misbehavior; failing the
  connection would let one inbound burst evict unrelated peers.

## Consequences

- The backend interface changes: `init` takes the pool dimensions, `submitRecv`
  loses its buffer parameter, `Completion` gains
  `recv_bytes`/`recv_token`/`recv_no_buffer`, and `recycleRecv` joins the
  contract. The interface doc in `src/net/completion/loop.zig` is the authority;
  the scripted test backends implement the same contract.
- `BackendOptions.read_buffer_bytes` names exact shared-pool buffer sizing. It
  neither limits frames nor supplies the outbound high-water mark;
  `max_frame_bytes` owns admission and ADR-0042 owns backpressure.
- Backend construction controls live only in `BackendOptions`.
  `initWithBackendOptions` applies them while constructing a backend;
  `initWithBackend` accepts only loop runtime policy because its supplied
  backend already owns the pool.
- `Conn` loses its `read_buf` and compaction state and gains the starved flag
  and intrusive starved-list link; the loop no longer allocates anything per
  accepted connection beyond the peer itself.
- The kqueue backend owns a scratch pool (lazily allocated, `read_buffers` cap)
  because a readiness backend reads at poll time; it remains compile-gated by
  `cross-check`, and the recurring macOS test suite executes its native path.
- The peer-scaling story changes: per-connection read-buffer memory is no longer
  a per-connection figure at all. The bench's transport-buffer narration follows
  the code.
- Evidence: pool-of-one contention with two connections (both served, the
  starved read resumed on recycle), a frame split across two completions
  applying exactly once via the spill, and recycle-exactly-once assertions
  across the scripted backends (`test/net/completion_loop_stream_test.zig`,
  `test/net/completion_loop_backpressure_test.zig`); the
  real-backend concurrency, churn, and dialer suites run unchanged over the new
  contract (`test/net/completion_loop_test.zig`,
  `test/net/completion_dialer_test.zig`).

## Notes

- [ADR-0041](ADR-0041-bounded-inbound-spill.md) owns the spill the split tail
  rides; [ADR-0042](ADR-0042-outbound-high-water-backpressure.md) owns the
  high-water park that still outranks a starved resume; both named this ADR as
  the completion loop's follow-up.
