# Plan — iroh at scale: the event-driven sidecar bridge

Status: historical snapshot. Stages 1–4 shipped; the companion ADR
[ADR-0057](../decisions/adr/ADR-0057-iroh-completion-loop-bridge.md) is
`accepted`. The superset lives in the sidecar, `iroh.LoopHost` is the loop
consumer, `zig build iroh-loop` serves many concurrent connections from one
thread, and `bench-peer-scaling`'s `served` row is the measured per-connection
cost. This doc is kept as the record of what was built, in order, and what
remains adjacent (the Deno demo wiring).

## What is already done (so this plan starts honest)

The iroh transport is, today, encrypted, discoverable, and identity-unified —
pancake-to-pancake, deterministically proven by `zig build iroh-interop`:

- **A — discovery / relays**: the netlayer takes a configurable, no-default
  `Reachability` (`direct`, `discovery`, `discovery_no_relay`,
  `local_discovery`) across the sidecar, the resident, the public C ABI, and all
  four bindings. The interop gate dials by node id **alone** through the
  `local_discovery` address book — the lookup half of the transport, proven with
  no relay or public infrastructure.
- **B — key unification**: one Ed25519 key per peer is at once the iroh node id,
  the OCapN locator designator, and the session signing key. The interop gate
  verifies this on both handshake halves over the live wire (`driver.connectVia`
  / `acceptVia` with a `.keyed` `Identity`).
- **F — durable identity**: a sturdyref (node id + swiss-number) survives an
  endpoint restart — same seed, same node id at a fresh address, same published
  cap reached through the locator recorded before the restart.

Two further milestones landed since (still pancake-to-pancake, still
thread-per-connection):

- **Real-internet reachability**: `zig build iroh-reachability` (opt-in,
  non-hermetic) dials by node id **alone over n0's public relays + DNS/pkarr** —
  the live counterpart of `iroh-interop`'s in-process dial-by-id.
- **The mesh**: `zig build iroh-mesh` proves a three-party handoff over iroh — A
  introduces B to C, and B reaches C **by the gifted node id**, withdraws, and
  calls, its one key serving as node id, session key, and named recipient.

Concurrency at pancake's target scale **is now done in the Zig core** (this
plan): `iroh.LoopHost` serves many connections from one loop thread, measured at
~1.1 GiB of core state for 500k. The blocking bindings (a thread or two per
connection, or a non-blocking-FFI threadpool) stay correct and remain the
default for small consumers; adopting the superset in a binding to retire the
thread-per-connection cap there is adjacent follow-on (see the bottom of this
doc), not this plan.

## The one idea

The sidecar already runs **one** tokio runtime multiplexing every QUIC stream
over one UDP socket. Surface that runtime's readiness to pancake's completion
loop through **one** wakeup fd and a drained ready-queue, and make frame I/O
non-blocking. Then N iroh connections cost one loop source plus the sidecar's
fixed threads — not N×2 blocking threads.

## Stages

Each stage ended green on its own gate before the next began. All four are done;
the bullets below record the shape that shipped.

### Stage 1 — Readiness primitive in the sidecar (Rust) — done

Shipped per-endpoint (the sidecar runs one runtime per endpoint, ADR-0055), with
a `socketpair` self-pipe as the wakeup primitive — portable across Linux and the
BSD/macOS cross-targets with no `cfg` fork. The `tools/meta_check.zig` parity
check covers the new functions; `zig build meta-check` is green. The planned
Rust-side self-pipe unit test is subsumed by the live `iroh-loop` gate, which
fires the fd over real endpoints end to end — stronger evidence than a unit test
on a self-connected pair, and no new cargo-test gate to maintain.

- Add to `transports/iroh/src/lib.rs`: a process-global readiness handle
  (`eventfd` on Linux behind a `cfg`, self-pipe fallback) created with the first
  endpoint. Pick the primitive here; record it in the ADR's "exact wakeup
  primitive" line.
- Spawn, on the existing runtime, per-connection tasks that mark a connection
  readable/writable/closed and write the wakeup fd.
- Expose `pancake_iroh_sidecar_readiness_fd() -> i32` and
  `pancake_iroh_sidecar_drain_ready(out_ptr, out_cap, out_len) -> i32` returning
  packed `(conn_handle, events)` records (`ptr + len`, caller-owned buffer, no
  per-call allocation).
- Gate: extend the `pancake_iroh_sidecar_` ABI parity check in
  `tools/meta_check.zig` to cover the new functions; `zig build meta-check`
  green. Add a Rust-side unit test that the fd fires on a self-connected pair.

### Stage 2 — Non-blocking frame I/O in the sidecar (Rust) — done

Shipped as `_conn_set_nonblocking` / `_try_read` / `_try_write` returning
`WOULD_BLOCK` (`-2`), plus `_set_nonblocking_accept` / `_try_accept` for the
listen side. The blocking calls stayed — a superset, not a replacement. Per-
connection state is `Arc`-refcounted with `tokio::sync::Notify` (one permit each
for read-room and write-work, so no lost wakeups) and 1 MiB bounded buffers. The
planned `WOULD_BLOCK`-then-frame unit test is likewise subsumed by `iroh-loop`,
which drives `try_read` / `try_write` and their re-arming live every run.

- Add `pancake_iroh_sidecar_try_read_frame` / `_try_write_frame` returning a
  `WOULD_BLOCK` code instead of parking.
- Keep the blocking calls — they remain the shipped path (ADR-0053). The new
  calls are a superset, not a replacement.
- Gate: a Rust test that a `try_read_frame` on an idle connection returns
  `WOULD_BLOCK`, then returns a frame after the peer writes and the fd fires.

### Stage 3 — A completion-loop source (Zig) — done

Shipped as `iroh.LoopHost` in the resident (`src/net/transport/iroh.zig`), not a
pure-Zig `src/driver/` source: the consumer links the Rust staticlib, so it
cannot sit in `libpancake`. It registers the readiness fd once, drains the
ready-queue on each wake, and drives non-blocking frame I/O on every
connection's `engine.Peer` (reusing the spill boundary handling of the TCP
loop's `completion.onRecvConsume`). The Netlayer / `ConnectedVat` contracts are
untouched. Gate: `zig build iroh-loop` serves 16 concurrent connections, 4 calls
each, from one loop thread.

- Add a new source under `src/driver/` (sibling of the kernel-fd source) that
  registers `readiness_fd()` once with the ADR-0051 loop, drains the ready-queue
  on wake, and resumes the fibers waiting on each `(conn, direction)`.
- Add a non-blocking variant of the resident's stream wrappers in
  `src/net/transport/iroh.zig` that drive `try_read_frame` / `try_write_frame`
  and yield on `WOULD_BLOCK`.
- The `Netlayer` (ADR-0043) and `ConnectedVat` (ADR-0053) contracts above do not
  change. A loop-driven consumer selects the non-blocking resident; the blocking
  `connectVia` / `acceptVia` path stays for simple consumers.
- Gate: a new Zig scenario — many concurrent iroh connections served from one
  loop on one thread — green under `zig build` (a sibling step like
  `iroh-interop`, since it links the sidecar).

### Stage 4 — Measure, don't project (Zig) — done

`bench-peer-scaling` gained a `served` scenario: the loop-driven per-connection
state (a warmed `engine.Peer` plus the `actors.Vat` and one published cap the
host holds inline) measures ~2.4 KiB per connection, ~1.1 GiB at 500k. Back-
pressure settled as a 1 MiB bounded flow-control ceiling per direction (a full
inbound buffer parks the sidecar reader so QUIC flow control reaches the sender;
a full outbound returns `WOULD_BLOCK`) — no typed abort needed. ADR-0057 moved
to `accepted`; `docs/boundaries.md` and `docs/shipped.md` carry the measured
claim.

- Add an iroh scenario to `bench-peer-scaling` and write a real `bytes_per_conn`
  / `mem_at_500k_gib` number for the loop-driven path.
- Decide back-pressure policy with the number in hand: bound the sidecar's
  per-connection inbound queue, surface overflow as a typed abort, document the
  bound.
- Update ADR-0057 status `proposed → accepted` and move the "at scale" line in
  `docs/boundaries.md` / `docs/shipped.md` from projection to measured.

## What this plan deliberately does not do

- **No native Zig QUIC.** ADR-0055's flip condition is unchanged; this plan
  removes the main reason to chase one.
- **No new transport semantics.** Discovery, relays, hole-punching, and identity
  are done (A/B/F). This is purely a concurrency/footprint bridge.
- **No change to the blocking consumer path.** Thread-per-connection stays
  correct and supported for small deployments.

## Known adjacent debt (not this plan, but record it here)

The cross-language `demo-rooms-iroh` and the Deno iroh tests in
`examples/apps/rooms/deno/server_test.ts` are flaky under load: an occasional
`Bus error` / `SIGSEGV` during Deno non-blocking-FFI **teardown** (a connection
released while a worker thread is still parked in a blocking read), plus message
loss / malformed frames under 5-way concurrent dials. This is a binding/demo
**teardown and harness** robustness issue — orthogonal to transport semantics,
which `iroh-interop` proves deterministically.

The fix's home now exists: the non-blocking surface above removes the
parked-read-during-release race **by construction**, and `iroh.LoopHost` is the
reference consumer that tears down flake-free every `iroh-loop` run (no parked
read to race a free; `Arc`-refcounted sidecar state). The remaining step is to
expose the superset through the netlayer C ABI (`src/c_abi/iroh/mod.zig`, which
today offers only the blocking frame shuttle) and rewire the Deno pump to drive
the readiness fd itself instead of parking blocking reads on FFI worker threads.
Until that lands, `iroh-interop` and `iroh-loop` are the authoritative iroh
gates; treat `demo-rooms-iroh` as illustrative, not load-bearing.
