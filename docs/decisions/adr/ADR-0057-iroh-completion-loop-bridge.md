---
id: ADR-0057
status: proposed
date: 2026-06-12
tags: [net_adapter, netlayer, iroh, transport, driver, completion-loop, performance]
decision: "iroh stays a sidecar (ADR-0055), but reaching pancake-scale concurrency over it needs an event-driven superset of the sidecar C ABI: one tokio runtime for all connections exposes a single readiness fd plus non-blocking try-read/try-write, and pancake's completion loop waits on that one fd and drains a ready-queue — so N iroh connections multiplex through one loop source instead of N blocking threads. This is the boundary 'full iroh hole-punching and P2P discovery at scale' rides on. Not implemented; the blocking ABI (ADR-0053) remains the shipped path."
supersedes: []
superseded_by: []
---

# ADR-0057 Scaling iroh: an event-driven sidecar bridge to the completion loop

## Context

ADR-0055 shipped iroh as a Rust sidecar behind a **blocking** C ABI: every
call (`connect`, `accept`, `read_frame`, `write_frame`) blocks the calling
thread until it completes. Each binding hides that block the native way — the
Rust binding runs a reader thread and a writer thread per connection, Deno uses
its non-blocking FFI threadpool. That model is correct and live-proven
(`zig build iroh-interop`), and for a handful of connections it is the right
amount of machinery.

It does not reach pancake-scale. Two settled facts collide:

- **ADR-0051** gives pancake a completion loop that multiplexes I/O over
  **kernel file descriptors**. iroh's QUIC streams are **userspace** — they live
  inside the sidecar's tokio runtime, on top of one UDP socket — so there is no
  per-stream fd to register. ADR-0051 explicitly reserved this case for the
  Netlayer contract rather than the loop.
- **ADR-0053** makes the blocking `ConnectedVat` the slice-1 consumer: one
  fiber blocks per connection. The `bench-peer-scaling` report targets ~500k
  connections at a sub-gigabyte footprint. A thread (or two) per iroh
  connection — or a blocked fiber per connection — is exactly the cost the
  completion loop exists to remove. The ceiling here is the **blocking ABI and
  the thread-per-connection workaround, not QUIC**: iroh's own runtime already
  multiplexes every stream over one socket on a small thread pool.

This engages three [First Principles](../../../AGENTS.md#first-principles):
**no hidden runtime** (the sidecar's tokio reactor is precisely the hidden
runtime; a scale bridge must make its readiness *explicit at the ABI*),
**performance is a public contract** (thread-per-connection is the measured
ceiling, so the fix is a design event, not a tuning knob), and the ADR-0051
reservation that userspace transports integrate *through* the Netlayer
contract, never by smuggling a second event loop into the core.

Peer discovery and hole-punching themselves are **not** the hard part: they are
sidecar-internal (iroh performs relay-assisted hole-punching and pkarr/DNS
discovery), and pancake already exposes the posture choice as the configurable,
no-default `Reachability` (ADR-0055 amendment + the discovery work that landed
alongside this ADR). What "full iroh hole-punching and P2P discovery **at
scale**" actually signs pancake up for is *serving the hundreds of thousands of
connections those mechanisms produce from pancake's own loop* — and that is
what this ADR scopes.

## Decision

**Keep the sidecar; add an event-driven superset to its C ABI.** ADR-0055's
sidecar boundary holds. On top of today's blocking calls, the sidecar gains a
readiness-based surface:

- **One runtime, one wakeup fd.** The sidecar already runs a single tokio
  runtime for all endpoints. It exposes **one** OS-level readiness handle (an
  `eventfd` on Linux, a self-pipe elsewhere) that pancake's completion loop
  registers **once**, alongside its kernel fds.
- **A drained ready-queue.** When any connection becomes readable, writable, or
  closed, the sidecar enqueues a `(conn, direction)` event and writes the
  wakeup fd. When the loop wakes, it calls a non-blocking
  `pancake_iroh_sidecar_drain_ready(...)` that returns the pending events
  (`ptr + len`, no allocation per call), and resumes exactly the fibers waiting
  on those connections.
- **Non-blocking frame I/O.** `try_read_frame` / `try_write_frame` return
  `WOULD_BLOCK` instead of parking; the loop re-arms the connection's interest
  and yields the fiber until the next readiness event. The frame unit is
  unchanged (one codec-self-delimited CapTP message), so the codec and session
  layers above never learn the transport changed.

Net effect: **N iroh connections multiplex through one loop source plus the
sidecar's fixed runtime threads**, not N×2 blocking threads. The Netlayer
(ADR-0043) and `ConnectedVat` (ADR-0053) contracts above are untouched; this is
a new *source* below them, the iroh sibling of the kernel-fd completion source.
It would live as a new driver source (`src/driver/…`) feeding the existing loop,
with the sidecar surface in `transports/iroh/` and `src/net_adapter/iroh.zig`.

## Scope (what this does not decide)

- **Not implemented.** This ADR records the shape and the cost, not code. The
  blocking ABI remains the shipped consumer path; the thread-per-connection
  bindings stay correct and supported. Nothing here is on a gate yet.
- **Native Zig QUIC stays rejected.** ADR-0055's flip condition is unchanged:
  this bridge makes the *sidecar* scale, which removes the main reason to chase
  a native rewrite. A native path still waits on iroh's protocols stabilizing
  and a production Zig QUIC stack existing.
- **The exact wakeup primitive** (`eventfd` vs self-pipe vs an io_uring
  registered fd) is a plan-time and per-OS choice, not fixed here.
- **Back-pressure policy** (how a slow reader bounds the sidecar's per-connection
  queue) is named in the plan, not settled here.

## Alternatives Considered

- **Thread-per-connection (status quo)**: correct, proven, simple. Rejected as
  the *scale* path only — it caps at thousands of connections, not the ~500k the
  footprint bench targets. Kept as the default; this bridge is the opt-in for
  scale.
- **Register QUIC's UDP socket fd in the loop and run QUIC in Zig**: that is
  native Zig QUIC by another name. Rejected — ADR-0055.
- **Busy-poll the sidecar from the loop**: rejected — it burns a core and
  defeats the point of a completion loop.

## Consequences

- New surfaces when built: an event-driven superset of the
  `pancake_iroh_sidecar_*` seam (held to one shape by the `tools/meta_check.zig`
  parity check, like the rest of the seam), a new completion-loop source in the
  driver, and a non-blocking variant of the resident's stream wrappers.
- `bench-peer-scaling` gains an iroh scenario once the source exists, turning
  the "at scale" claim into a measured number rather than a projection.
- Until then, the honest boundary stands: **iroh is encrypted, discoverable,
  and identity-unified pancake-to-pancake today (ADR-0055 + this cycle's A/B/F),
  and it scales to as many connections as the host can hold threads for. The
  loop-integrated, 500k-connection story is this ADR's proposed work.**

## Notes

- Companion plan: [`docs/planning/iroh-completion-loop-bridge.md`](../../planning/iroh-completion-loop-bridge.md).
- Builds on ADR-0051 (completion-loop dialer), ADR-0053 (blocking pump /
  single fiber), and ADR-0055 (the iroh sidecar).
