---
id: ADR-0057
status: accepted
date: 2026-06-12
tags: [net, netlayer, iroh, transport, driver, completion-loop, performance]
decision: "iroh stays a sidecar (ADR-0055), and reaching pancake-scale concurrency over it is the netlayer's one I/O model: one tokio runtime per endpoint exposes a single readiness fd plus non-blocking try-read/try-write, and the host waits on that one fd and drains a ready-queue — so N iroh connections multiplex through one loop thread instead of N blocking threads. Shipped: the sidecar exposes the readiness fd + drain, the resident's `iroh.LoopHost` is the loop consumer, the public iroh netlayer C ABI (`pancake_iroh_netlayer_*`) is loop-only — `readiness_fd` + `drain_ready`, armed at construction, with no blocking frame surface — and `zig build iroh-loop` proves many concurrent connections served from one thread. Every binding parks on the readiness fd natively in its own idiom (gated by `bindings-iroh-loop`)."
supersedes: []
superseded_by: []
---

# ADR-0057 Scaling iroh: an event-driven sidecar bridge to the completion loop

## Context

ADR-0055 ships iroh as a Rust sidecar. iroh's QUIC streams are **userspace** —
they live inside the sidecar's tokio runtime, on top of one UDP socket — so a
host has no per-stream kernel fd to wait on. The question this ADR settles is
how a pancake host serves pancake-scale concurrency over that sidecar.

Two settled facts shape the answer:

- **ADR-0051** gives pancake a completion loop that multiplexes I/O over
  **kernel file descriptors**. iroh's streams have no per-stream fd to register,
  so ADR-0051 reserved this case for the Netlayer contract rather than the loop.
- **ADR-0053**'s footprint target is ~500k connections at a sub-gigabyte
  footprint (`bench-peer-scaling`). A thread per connection cannot reach that,
  and the ceiling is the per-connection thread, **not QUIC**: iroh's own runtime
  already multiplexes every stream over one socket on a small thread pool. The
  cost to remove is the thread-per-connection bridging the sidecar's I/O onto a
  pancake host.

This engages three [First Principles](../../../AGENTS.md#first-principles): **no
hidden runtime** (the sidecar's tokio reactor is a runtime, so a scale bridge
must make its readiness _explicit at the ABI_), **performance is a public
contract** (a per-connection thread is a design event, not a tuning knob), and
the ADR-0051 reservation that userspace transports integrate _through_ the
Netlayer contract, never by smuggling a second event loop into the core.

Peer discovery and hole-punching are sidecar-internal: iroh performs
relay-assisted hole-punching and pkarr/DNS discovery, and pancake exposes the
posture choice as the no-default `Reachability` (ADR-0055). What scaling iroh
signs pancake up for is _serving the hundreds of thousands of connections those
mechanisms produce from pancake's own loop_ — and that is what this ADR scopes.

## Decision

**Keep the sidecar; make the readiness loop the netlayer's one I/O model.**
ADR-0055's sidecar boundary holds. The sidecar's internal seam keeps a blocking
dial (the dial handshake itself blocks the caller), but the public iroh netlayer
C ABI carries no blocking frame surface: it is the loop, armed when the netlayer
is constructed. The sidecar exposes a readiness-based surface:

- **One runtime, one wakeup fd.** Each endpoint runs a single tokio runtime
  multiplexing all its connections. It exposes **one** OS-level readiness handle
  that a pancake loop registers **once**, alongside its kernel fds. The
  readiness fd is **per-endpoint**: the sidecar runs one runtime per endpoint
  (ADR-0055), so each endpoint owns its own wakeup fd and `endpoint_drain_ready`
  takes the endpoint; the loop registers as many fds as it has local endpoints
  (typically one).
- **A drained ready-queue.** When any connection becomes readable, writable, or
  closed, the sidecar enqueues a `(conn, direction)` event and writes the wakeup
  fd. When the loop wakes, it calls a non-blocking
  `pancake_iroh_sidecar_drain_ready(...)` that returns the pending events
  (`ptr + len`, no allocation per call), and resumes exactly the fibers waiting
  on those connections.
- **Non-blocking frame I/O.** `try_read_frame` / `try_write_frame` return
  `WOULD_BLOCK` instead of parking; the loop re-arms the connection's interest
  and yields the fiber until the next readiness event. The frame unit is
  unchanged (one codec-self-delimited CapTP message), so the codec and session
  layers above never learn the transport changed.

Net effect: **N iroh connections multiplex through one loop thread plus the
sidecar's fixed runtime threads**, not N×2 blocking threads. The Netlayer
(ADR-0043) and `ConnectedVat` (ADR-0053) contracts above are untouched; this is
a new _source_ below them, the iroh sibling of the kernel-fd completion source.
It lives as `iroh.LoopHost` in the resident (`src/net/transport/iroh.zig`)
rather than pure-Zig `src/driver/`, because the consumer links the Rust
staticlib; the sidecar surface is in `transports/iroh/` (see Consequences for
the placement rationale).

## Scope (what this decides, and what it leaves)

- **Implemented and gated.** The readiness surface ships in the sidecar
  (`pancake_iroh_sidecar_endpoint_readiness_fd` / `_drain_ready` /
  `_set_nonblocking_accept` / `_try_accept`, and `_conn_set_nonblocking` /
  `_try_read` / `_try_write`), the resident carries `iroh.LoopHost`, the public
  iroh netlayer C ABI is loop-only (`pancake_iroh_netlayer_readiness_fd` +
  `_drain_ready`, armed at `netlayer_new`), and `zig build iroh-loop` serves
  many concurrent connections from one loop thread. The public netlayer surface
  carries no blocking frame ABI.
- **The wakeup primitive is a self-pipe** (`socketpair`, both ends
  non-blocking): portable across Linux and the BSD/macOS targets the project
  cross-compiles for, no `cfg` fork, and registered with the loop's `poll` like
  any other fd. An `eventfd` or io_uring registered fd would shave one syscall
  but split the code per-OS; the self-pipe is the boring choice that holds.
- **Back-pressure is a bounded flow-control ceiling, not a drop or an abort.**
  Each direction is bounded at 1 MiB (`NB_BUFFER_BOUND`). A full inbound buffer
  parks the sidecar's reader task, so QUIC flow control reaches the remote
  sender; a full outbound buffer returns `WOULD_BLOCK` to the loop, which
  re-arms on the next `EV_WRITABLE`. A slow reader throttles its partner rather
  than tripping an error, so overflow needs no typed abort.
- **Native Zig QUIC stays rejected.** ADR-0055's flip condition is unchanged:
  this bridge makes the _sidecar_ scale, which removes the main reason to chase
  a native rewrite. A native path still waits on iroh's protocols stabilizing
  and a production Zig QUIC stack existing.

## Alternatives Considered

- **Thread-per-connection**: correct, proven, and simple, but it caps at
  thousands of connections, not the ~500k the footprint bench targets, so it is
  not the scale path. The netlayer keeps one I/O model — the loop — so there is
  no second blocking path to maintain.
- **Register QUIC's UDP socket fd in the loop and run QUIC in Zig**: that is
  native Zig QUIC by another name. Rejected — ADR-0055.
- **Busy-poll the sidecar from the loop**: rejected — it burns a core and
  defeats the point of a completion loop.

## Consequences

- New surfaces, shipped: an event-driven superset of the
  `pancake_iroh_sidecar_*` seam (held to one shape by the `tools/meta_check.zig`
  parity check, like the rest of the seam) and a non-blocking variant of the
  resident's stream wrappers driven by `iroh.LoopHost`.
- **The loop consumer lives in the resident (`src/net/transport/iroh.zig`), not
  pure-Zig `src/driver/`.** `LoopHost` registers the sidecar readiness fd,
  drains the ready-queue, and drives non-blocking frame I/O on each connection's
  `engine.Peer`, so it must link the Rust staticlib and cannot sit in
  `src/driver/`. It is the iroh sibling of the kernel-fd loop in spirit; the
  Netlayer (ADR-0043) and `ConnectedVat` (ADR-0053) contracts above are
  untouched.
- **Measured, not projected.** `bench-peer-scaling`'s `served` scenario weighs
  the loop-driven per-connection state (a warmed `engine.Peer` plus the
  `actors.Vat` and one published cap the host holds inline): ~2.4 KiB per
  connection, ~1.1 GiB at 500k. The sidecar adds its bounded inbound/outbound
  buffers per connection in the Rust heap, allocated on first traffic. The
  blocking thread-per-connection path adds the same core state _plus_ an OS
  thread (or two) per connection — the cost this bridge removes.
- **Teardown is flake-free by construction.** The loop never parks a blocking
  read on a connection, so releasing one cannot race a parked worker. The
  sidecar's per-connection state is `Arc`-refcounted and its tasks own their
  streams, so `conn_free` while tasks are live is safe; the loop removes a
  connection's ready-queue routing before freeing it, so stale events resolve to
  no slot. `iroh-loop` exercises this teardown every run, and because the loop
  is the netlayer's only model, every binding inherits the same teardown safety.
- The honest boundary reads: **iroh is encrypted, discoverable, and
  identity-unified pancake-to-pancake (ADR-0055 + A/B/F), and serves many
  connections from one loop thread (this ADR), measured at ~1.1 GiB of core
  state for 500k. A live 500k-connection socket run still needs a load harness
  (`bench-peer-scaling` Phase 2).**

## The readiness fd is the binding contract

[`docs/vision.md`](../../vision.md) holds a peer in _any_ binding to the same
scale bar as a native one ("a peer written against any binding… with no
asterisks"; The Number is the whole project's, not Zig's). The loop is the
netlayer's one model, and the public ABI hands every host the same primitive: a
single OS **readiness fd** (`pancake_iroh_netlayer_readiness_fd`) it parks on
with its own poller, plus a non-blocking `pancake_iroh_netlayer_drain_ready`.
Each binding parks on that fd natively, with no dedicated polling thread and no
busy-poll, and each is proven by a many-connection gate the way `iroh-loop`
proves the Zig resident:

- **Deno** — `IrohLoop` parks a `node:net` socket on a dup of the readiness fd
  and drains on its `data` event.
- **Python** — `_IrohLoop` registers the fd with the asyncio event loop
  (`add_reader`) and drains in the callback — no thread, no
  `call_soon_threadsafe`. Gate: `zig build python-iroh-loop`.
- **Rust** — `IrohLoop` registers the fd with tokio (`AsyncFd`) and drains when
  it signals, waking per-connection tasks. Gate: `zig build rust-iroh-loop`.
- **Racket** — the loop thread parks on the fd natively via
  `unsafe-file-descriptor->semaphore`, so the place's poller wakes it without
  freezing the cooperative scheduler. Gate: `zig build racket-iroh-loop`.

`zig build bindings-iroh-loop` runs the three binding gates together. Exposing
the fd, rather than an in-ABI blocking wait, is what lets each runtime integrate
the endpoint into its own reactor instead of dedicating a thread to it.

## Notes

- Companion plan:
  [`docs/planning/iroh-completion-loop-bridge.md`](../../planning/iroh-completion-loop-bridge.md).
- Builds on ADR-0051 (completion-loop dialer), ADR-0053 (blocking pump / single
  fiber), and ADR-0055 (the iroh sidecar).
